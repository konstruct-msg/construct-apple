//
//  NowPlaying.swift
//  Construct Messenger
//
//  A music file sent in a chat plays on the lock screen and in Control Center like any track:
//  play, pause, and the position bar. Only music — a voice message is part of a conversation,
//  and nothing about the conversation goes there. What the lock screen shows is the track's
//  file name, never the chat or who sent it.
//

import Foundation
#if canImport(MediaPlayer)
import MediaPlayer
#endif

@MainActor
enum NowPlaying {

    struct State: Equatable {
        var title: String
        var duration: TimeInterval
        var elapsed: TimeInterval
        var isPlaying: Bool
    }

    /// What the lock screen is given. A file name without its extension, as a track title.
    static func info(_ state: State) -> [String: Any] {
        #if canImport(MediaPlayer)
        let title = (state.title as NSString).deletingPathExtension
        return [
            MPMediaItemPropertyTitle: title.isEmpty ? state.title : title,
            MPMediaItemPropertyPlaybackDuration: state.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: state.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: state.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        #else
        return [:]
        #endif
    }

    /// `nil` takes the track off the lock screen.
    static func publish(_ state: State?) {
        #if canImport(MediaPlayer)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = state.map(info)
        #endif
    }

    struct Commands {
        var play: () -> Bool
        var pause: () -> Bool
        var toggle: () -> Bool
        var seek: (TimeInterval) -> Bool
    }

    private static var installed = false

    /// Once per process: the lock screen's buttons, routed to the player. A handler answers false
    /// when nothing is loaded, and the system greys the button.
    static func install(_ commands: Commands) {
        #if canImport(MediaPlayer)
        guard !installed else { return }
        installed = true
        let center = MPRemoteCommandCenter.shared()
        func status(_ ok: Bool) -> MPRemoteCommandHandlerStatus { ok ? .success : .noActionableNowPlayingItem }
        center.playCommand.addTarget { _ in MainActor.assumeIsolated { status(commands.play()) } }
        center.pauseCommand.addTarget { _ in MainActor.assumeIsolated { status(commands.pause()) } }
        center.togglePlayPauseCommand.addTarget { _ in MainActor.assumeIsolated { status(commands.toggle()) } }
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            return MainActor.assumeIsolated { status(commands.seek(event.positionTime)) }
        }
        #endif
    }
}
