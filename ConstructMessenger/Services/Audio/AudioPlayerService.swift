//
//  AudioPlayerService.swift
//  Construct Messenger
//
//  Single active player — starting a new message stops the previous.
//  Switches AVAudioSession to .playback during playback.
//

import AVFoundation
import Combine

@MainActor
final class AudioPlayerService: NSObject, ObservableObject {

    static let shared = AudioPlayerService()

    // MARK: - Published state

    @Published private(set) var playingMediaId: String?
    @Published private(set) var progress: Double = 0     // 0.0 – 1.0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var totalDuration: Double = 0

    // MARK: - Private

    private var player: AVAudioPlayer?
    private var progressTimer: Timer?

    private override init() {}

    // MARK: - Public API

    func isPlaying(_ mediaId: String) -> Bool { playingMediaId == mediaId }

    /// Toggle play/pause for the given mediaId, loading audio from `data`.
    func togglePlay(mediaId: String, data: Data) {
        if playingMediaId == mediaId {
            // Pause or resume
            if let p = player {
                if p.isPlaying { pause() } else { resume() }
            }
            return
        }
        // New track — stop previous
        stop()
        play(mediaId: mediaId, data: data)
    }

    func stop() {
        player?.stop()
        player = nil
        stopProgressTimer()
        playingMediaId = nil
        progress       = 0
        elapsed        = 0
        totalDuration  = 0
        deactivateSession()
    }

    // MARK: - Private playback

    private func play(mediaId: String, data: Data) {
        do {
            activateSession()
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            p.prepareToPlay()
            p.play()

            player        = p
            playingMediaId = mediaId
            totalDuration  = p.duration
            progress       = 0
            elapsed        = 0
            startProgressTimer()
        } catch {
            print("AudioPlayerService: failed to play \(mediaId) — \(error)")
        }
    }

    private func pause() {
        player?.pause()
        stopProgressTimer()
    }

    private func resume() {
        player?.play()
        startProgressTimer()
    }

    // MARK: - Progress timer

    private func startProgressTimer() {
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func tick() {
        guard let p = player, p.isPlaying else { return }
        elapsed  = p.currentTime
        progress = p.duration > 0 ? p.currentTime / p.duration : 0
    }

    // MARK: - Session management

    private func activateSession() {
        #if os(iOS) || targetEnvironment(macCatalyst)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        #endif
    }

    private func deactivateSession() {
        #if os(iOS) || targetEnvironment(macCatalyst)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

// MARK: - AVAudioPlayerDelegate

extension AudioPlayerService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.stopProgressTimer()
            self?.progress       = 0
            self?.elapsed        = 0
            self?.playingMediaId = nil
            self?.player         = nil
            self?.deactivateSession()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in self?.stop() }
    }
}
