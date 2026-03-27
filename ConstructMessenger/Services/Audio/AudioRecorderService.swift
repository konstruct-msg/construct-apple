//
//  AudioRecorderService.swift
//  Construct Messenger
//
//  Records voice messages as AAC/M4A with live waveform sampling.
//  Encoding: AAC, 64 kbps, 44.1 kHz, mono — high quality, small file.
//

import AVFoundation
import Combine

@MainActor
final class AudioRecorderService: ObservableObject {

    static let shared = AudioRecorderService()

    // MARK: - State

    enum RecordingState: Equatable {
        case idle
        case recording(duration: TimeInterval, waveform: [Float])
        case recorded(url: URL, duration: TimeInterval, waveform: [Float])

        static func == (lhs: RecordingState, rhs: RecordingState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): return true
            case (.recording(let d1, _), .recording(let d2, _)): return d1 == d2
            case (.recorded(let u1, let d1, _), .recorded(let u2, let d2, _)): return u1 == u2 && d1 == d2
            default: return false
            }
        }
    }

    @Published private(set) var state: RecordingState = .idle

    // MARK: - Private state

    private var recorder: AVAudioRecorder?
    private var meteringTimer: Timer?
    private var startDate: Date?
    private var waveformSamples: [Float] = []

    /// Number of waveform samples to collect per recording (~100 at 10 Hz = 10 seconds resolution).
    private let targetSampleCount = 100
    private let meteringInterval: TimeInterval = 0.05   // 50 ms — smooth live animation
    private let maxDuration: TimeInterval = 300         // 5 minutes

    // MARK: - Init

    private init() {}

    // MARK: - Public API

    /// Start a new recording. Requests microphone permission if needed.
    /// Throws `RecorderError` on permission denial or setup failure.
    func startRecording() async throws {
        guard case .idle = state else { return }

        let granted = await requestMicrophonePermission()
        guard granted else { throw RecorderError.permissionDenied }

        let url = Self.tempFileURL()

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        try configureAudioSession()

        let rec = try AVAudioRecorder(url: url, settings: settings)
        rec.isMeteringEnabled = true
        guard rec.record() else { throw RecorderError.recordFailed }

        recorder   = rec
        startDate  = Date()
        waveformSamples = []
        state = .recording(duration: 0, waveform: [])

        startMeteringTimer()
    }

    /// Stop the current recording and transition to `.recorded` state.
    func stopRecording() {
        guard case .recording = state, let rec = recorder else { return }

        stopMeteringTimer()
        rec.stop()

        let duration = Date().timeIntervalSince(startDate ?? Date())
        let url = rec.url
        let waveform = normalizedWaveform()

        recorder   = nil
        startDate  = nil
        state = .recorded(url: url, duration: duration, waveform: waveform)

        deactivateAudioSession()
    }

    /// Discard current recording/recorded file and return to `.idle`.
    func cancel() {
        stopMeteringTimer()
        if let rec = recorder { rec.stop() }
        if case .recording(_, _) = state, let rec = recorder {
            try? FileManager.default.removeItem(at: rec.url)
        }
        if case .recorded(let url, _, _) = state {
            try? FileManager.default.removeItem(at: url)
        }
        recorder   = nil
        startDate  = nil
        waveformSamples = []
        state = .idle
        deactivateAudioSession()
    }

    /// Reset to `.idle` after the recorded file has been consumed (uploaded + sent).
    func resetAfterSend() {
        recorder   = nil
        startDate  = nil
        waveformSamples = []
        state = .idle
    }

    // MARK: - Errors

    enum RecorderError: LocalizedError {
        case permissionDenied
        case recordFailed

        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "Microphone access denied"
            case .recordFailed:     return "Failed to start recording"
            }
        }
    }

    // MARK: - Metering timer

    private func startMeteringTimer() {
        meteringTimer = Timer.scheduledTimer(withTimeInterval: meteringInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sampleMetering() }
        }
    }

    private func stopMeteringTimer() {
        meteringTimer?.invalidate()
        meteringTimer = nil
    }

    private func sampleMetering() {
        guard let rec = recorder, rec.isRecording else { return }
        rec.updateMeters()

        let duration = Date().timeIntervalSince(startDate ?? Date())

        // Average power comes in dBFS (-160…0). Map to 0.0–1.0.
        let dB = rec.averagePower(forChannel: 0)
        let linear = max(0, (dB + 50) / 50)    // -50 dBFS → 0, 0 dBFS → 1
        waveformSamples.append(Float(linear))

        // Cap live sample array at targetSampleCount * 4 — downsampled on stop.
        if waveformSamples.count > targetSampleCount * 4 {
            waveformSamples.removeFirst()
        }

        // Auto-stop at max duration.
        if duration >= maxDuration { stopRecording(); return }

        state = .recording(duration: duration, waveform: Array(waveformSamples.suffix(40)))
    }

    // MARK: - Waveform normalization

    /// Downsample the raw metering buffer to exactly `targetSampleCount` values.
    private func normalizedWaveform() -> [Float] {
        guard !waveformSamples.isEmpty else { return Array(repeating: 0, count: targetSampleCount) }

        let target = targetSampleCount
        if waveformSamples.count <= target { return waveformSamples }

        let step = Float(waveformSamples.count) / Float(target)
        return (0..<target).map { i in
            let start = Int(Float(i) * step)
            let end   = min(Int(Float(i + 1) * step), waveformSamples.count)
            let slice = waveformSamples[start..<end]
            return slice.reduce(0, +) / Float(slice.count)
        }
    }

    // MARK: - Helpers

    private static func tempFileURL() -> URL {
        let name = "voice_\(UUID().uuidString).m4a"
        return FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func configureAudioSession() throws {
        #if os(iOS) || targetEnvironment(macCatalyst)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        #endif
    }

    private func deactivateAudioSession() {
        #if os(iOS) || targetEnvironment(macCatalyst)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
