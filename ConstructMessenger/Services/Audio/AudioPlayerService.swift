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
    /// The current track is loaded but paused. Until 2026-10-09 a pause changed nothing published
    /// — `isPlaying` read only which track was current — so the bubble kept its pause icon.
    @Published private(set) var isPaused = false
    /// Playback speed, kept across tracks and launches: 1, 1.25, 1.5 or 2.
    @Published private(set) var rate: Float = AudioPlayerService.storedRate()

    /// Fired when a track finishes playing **naturally** (not when stopped/replaced).
    /// Carries the mediaId that just finished. Used for continuous voice playback —
    /// the active chat installs a handler to auto-advance to the next voice message.
    var onTrackFinished: ((String) -> Void)?

    // MARK: - Private

    private var player: AVAudioPlayer?
    private var progressTimer: Timer?

    private override init() {}

    // MARK: - Public API

    /// Sounding now — the play/pause icon.
    func isPlaying(_ mediaId: String) -> Bool { playingMediaId == mediaId && !isPaused }

    /// Loaded, playing or paused — the position on the waveform and the time left.
    func isActive(_ mediaId: String) -> Bool { playingMediaId == mediaId }

    // MARK: Speed

    static let rates: [Float] = [1, 1.25, 1.5, 2]
    private static let rateKey = "voice.playbackRate"

    /// The speed after `rate` in the cycle; an unknown one starts the cycle again.
    static func nextRate(after rate: Float) -> Float {
        guard let i = rates.firstIndex(of: rate) else { return rates[0] }
        return rates[(i + 1) % rates.count]
    }

    func cycleRate() {
        rate = Self.nextRate(after: rate)
        UserDefaults.standard.set(rate, forKey: Self.rateKey)
        player?.rate = rate
    }

    private static func storedRate() -> Float {
        let stored = UserDefaults.standard.float(forKey: rateKey)
        return rates.contains(stored) ? stored : 1
    }

    // MARK: Seeking

    /// Move to `fraction` (0…1) of the track. The current track keeps playing or stays paused;
    /// another one starts there.
    func seek(mediaId: String, data: Data, to fraction: Double) {
        let fraction = min(max(fraction, 0), 1)
        if playingMediaId != mediaId {
            stop()
            play(mediaId: mediaId, data: data)
        }
        guard let p = player, playingMediaId == mediaId else { return }
        p.currentTime = fraction * p.duration
        elapsed = p.currentTime
        progress = fraction
    }

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
        isPaused       = false
        progress       = 0
        elapsed        = 0
        totalDuration  = 0
        deactivateSession()
    }

    // MARK: - Private playback

    private func play(mediaId: String, data: Data) {
        // One sound at a time: a video note playing in place folds back.
        VideoNotePlayback.shared.collapse()
        do {
            activateSession()
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            p.enableRate = true
            p.prepareToPlay()
            p.rate = rate
            p.play()

            player        = p
            playingMediaId = mediaId
            totalDuration  = p.duration
            isPaused       = false
            progress       = 0
            elapsed        = 0
            startProgressTimer()
        } catch {
            Log.info("AudioPlayerService: failed to play \(mediaId) — \(error)")
        }
    }

    private func pause() {
        player?.pause()
        isPaused = true
        stopProgressTimer()
    }

    private func resume() {
        player?.rate = rate
        player?.play()
        isPaused = false
        startProgressTimer()
    }

    // MARK: - Progress timer

    private func startProgressTimer() {
        stopProgressTimer()
        // `.common`, not the default mode `scheduledTimer` uses: the default mode does not run
        // while a scroll view tracks a finger, so the progress froze whenever the list moved.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
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
            guard let self else { return }
            let finishedId = self.playingMediaId
            self.stopProgressTimer()
            self.progress       = 0
            self.elapsed        = 0
            self.isPaused       = false
            self.playingMediaId = nil
            self.player         = nil
            self.deactivateSession()
            if flag, let finishedId { self.onTrackFinished?(finishedId) }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in self?.stop() }
    }
}
