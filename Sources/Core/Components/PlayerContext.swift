// The MIT License (MIT)
//
// ModernAVPlayer
// Copyright (c) 2018 Raphael Ankierman <raphael.ankierman@radiofrance.com>
//
// PlayerContext.swift
// Created by raphael ankierman on 21/02/2018.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import AVFoundation

//sourcery: AutoMockable
protocol PlayerContextDelegate: class {
    func playerContext(didStateChange state: ModernAVPlayer.State)
    func playerContext(didCurrentMediaChange media: PlayerMedia?)
    func playerContext(didCurrentTimeChange currentTime: Double)
    func playerContext(didItemDurationChange itemDuration: Double?)
    func playerContext(unavailableActionReason: PlayerUnavailableActionReason)
    func playerContext(didItemPlayToEndTime endTime: Double)
}

//sourcery: AutoMockable
protocol PlayerContext: MediaPlayer {
    var audioSession: AudioSessionService { get }
    var bgToken: UIBackgroundTaskIdentifier? { get set }
    var config: PlayerConfiguration { get }
    var currentMedia: PlayerMedia? { get set }
    var currentItem: AVPlayerItem? { get }
    var delegate: PlayerContextDelegate? { get }
    var itemDuration: Double? { get }
    var nowPlaying: NowPlaying { get }
    var plugins: [PlayerPlugin] { get }
    var state: PlayerState! { get }
    
    func changeState(state: PlayerState)
}

final class ModernAVPlayerContext: NSObject, PlayerContext {
    
    // MARK: - Inputs
    
    let audioSession: AudioSessionService
    let config: PlayerConfiguration
    let nowPlaying: NowPlaying
    let player: AVPlayer
    let plugins: [PlayerPlugin]
    var loopMode = false
    private let seekService: SeekService

    weak var delegate: PlayerContextDelegate?
    
    // MARK: - Variables
    
    var bgToken: UIBackgroundTaskIdentifier?
    var currentItem: AVPlayerItem? {
        return player.currentItem
    }
    var currentMedia: PlayerMedia? {
        didSet { delegate?.playerContext(didCurrentMediaChange: currentMedia) }
    }
    var currentTime: Double {
        return player.currentTime().seconds
    }
    var itemDuration: Double? {
        return currentItem?.duration.seconds
    }
    var remoteCommands: [ModernAVPlayerRemoteCommand]? {
        didSet {
            let msg = "Set \(remoteCommands?.count ?? 0) remote command(s)"
            ModernAVPlayerLogger.instance.log(message: msg, domain: .remoteCommand)
        }
    }

    var state: PlayerState! {
        didSet {
            ModernAVPlayerLogger.instance.log(message: state.type.description, domain: .state)
            state.contextUpdated()
            delegate?.playerContext(didStateChange: state.type)
        }
    }

    // MARK: - LifeCycle

    init(player: AVPlayer,
         config: PlayerConfiguration,
         nowPlaying: NowPlaying = ModernAVPlayerNowPlayingService(),
         audioSession: AudioSessionService = ModernAVPlayerAudioSessionService(),
         plugins: [PlayerPlugin],
         seekService: SeekService = ModernAVPlayerSeekService()) {
        self.player = player
        self.config = config
        self.nowPlaying = nowPlaying
        self.audioSession = audioSession
        self.plugins = plugins
        self.seekService = seekService
        super.init()

        ModernAVPlayerLogger.instance.log(message: "Init", domain: .lifecycleState)
        setAudioSessionCategory()
        setAllowsExternalPlayback()

        // defer use to execute didSet state instruction
        //swiftlint:disable inert_defer
        defer {
            state = InitState(context: self)
            plugins.forEach { $0.didInit(player: player) }
        }
    }

    deinit {
        ModernAVPlayerLogger.instance.log(message: "Deinit", domain: .lifecycleState)
    }

    private func setAudioSessionCategory() {
        audioSession.setCategory(config.audioSessionCategory)
    }
    
    private func setAllowsExternalPlayback() {
        player.allowsExternalPlayback = config.allowsExternalPlayback
    }

    // MARK: - Public functions

    func changeState(state: PlayerState) {
        self.state = state
    }

    func pause() {
        state.pause()
    }

    func seek(position: Double) {
        let newPosition = seekService.boundedPosition(position, media: currentMedia, duration: itemDuration)
        if let boundedPosition = newPosition.value {
            state.seek(position: boundedPosition)
        } else if let reason = newPosition.reason {
            unaivalableCommand(reason: reason)
        }
    }

    func seek(offset: Double) {
        let position = currentTime + offset
        seek(position: position)
    }

    func stop() {
        state.stop()
    }

    func load(media: PlayerMedia, autostart: Bool, position: Double?) {
        let previousMedia = currentMedia
        currentMedia = media
        plugins.forEach { $0.didMediaChanged(media, previousMedia: previousMedia) }
        state.load(media: media, autostart: autostart, position: position)
    }
    
    func play() {
        state.play()
    }
    
    func updateMetadata(_ metadata: PlayerMediaMetadata) {
        guard let media = currentMedia
            else { unaivalableCommand(reason: .loadMediaFirst, metadata: true); return }
        
        media.setMetadata(metadata)
        nowPlaying.update(metadata: metadata, duration: nil, isLive: nil)
    }

    // MARK: - Helper

    private func unaivalableCommand(reason: PlayerUnavailableActionReason, metadata: Bool = false) {
        let message: String
        switch reason {
        case .seekOverstepTime:
            message = "Seek position should not exceed item end position"
        case .itemDurationNotSet:
            message = "Seek failed, item duration not set"
        case .loadMediaFirst:
            message = metadata ? "Load a media before update metadata" : "Seek failed, load a media first"
        default:
            assertionFailure("all context cases must be set")
            message = ""
        }
        ModernAVPlayerLogger.instance.log(message: message, domain: .unavailableCommand)
        delegate?.playerContext(unavailableActionReason: reason)
    }
}
