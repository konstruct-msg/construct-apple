//
//  VideoNotePlayback.swift
//  Construct Messenger
//
//  The one video note playing with sound, expanded in place in the transcript.
//  `decisions/video-notes-are-uncropped-and-expand.md` (revised 2026-10-05: a tap expands the
//  note inside the chat rather than opening the gallery).
//
//  One at a time, and one sound at a time: expanding a note stops a voice message, and a voice
//  message collapses the note (`AudioPlayerService.play`). The bubble decides nothing — it shows
//  what this says and forwards taps.
//

import AVFoundation
import Foundation

@MainActor
@Observable
final class VideoNotePlayback {
    static let shared = VideoNotePlayback()

    struct Key: Hashable {
        let messageId: String
        let itemIndex: Int
    }

    /// The speeds a tap on the speed chip cycles through, as for voice.
    static let rates: [Float] = [1, 1.5, 2]
    private static let tick = CMTime(value: 1, timescale: 10)

    private(set) var expanded: Key?
    private(set) var player: AVPlayer?
    private(set) var isPaused = false
    /// 0…1 of the note.
    private(set) var progress: Double = 0
    private(set) var remaining: TimeInterval = 0
    private(set) var rate: Float = 1

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    private init() {}

    /// A tap on the note: expand and play it, or pause / resume the one already expanded.
    func tap(_ key: Key, url: URL) {
        guard expanded == key else {
            expand(key, url: url)
            return
        }
        if isPaused { resume() } else { pause() }
    }

    func cycleRate() {
        let next = Self.rates.firstIndex(of: rate).map { (($0 + 1) % Self.rates.count) } ?? 0
        rate = Self.rates[next]
        player?.defaultRate = rate
        if !isPaused { player?.rate = rate }
    }

    /// Back to the muted loop. Called when the note ends, scrolls away, the chat closes, or
    /// something else starts playing.
    func collapse() {
        guard expanded != nil || player != nil else { return }
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player?.pause()
        player = nil
        expanded = nil
        isPaused = false
        progress = 0
        remaining = 0
        rate = 1
        deactivateSession()
    }

    func collapse(ifShowing key: Key) {
        if expanded == key { collapse() }
    }

    // MARK: - Private

    private func expand(_ key: Key, url: URL) {
        collapse()
        AudioPlayerService.shared.stop()
        activateSession()

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.defaultRate = rate
        timeObserver = player.addPeriodicTimeObserver(forInterval: Self.tick, queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.update(time: time, item: item) }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.collapse() }
        }
        self.player = player
        expanded = key
        isPaused = false
        player.playImmediately(atRate: rate)
    }

    private func pause() {
        player?.pause()
        isPaused = true
    }

    private func resume() {
        player?.playImmediately(atRate: rate)
        isPaused = false
    }

    private func update(time: CMTime, item: AVPlayerItem) {
        let duration = item.duration.seconds
        guard duration.isFinite, duration > 0 else { return }
        progress = min(1, max(0, time.seconds / duration))
        remaining = max(0, duration - time.seconds)
    }

    private func activateSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
        #endif
    }

    private func deactivateSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
