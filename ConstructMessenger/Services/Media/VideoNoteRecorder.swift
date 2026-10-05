//
//  VideoNoteRecorder.swift
//  Construct Messenger
//
//  Records a video note: camera and microphone into one file, with pause and a camera switch
//  in the middle. `decisions/video-notes-are-uncropped-and-expand.md`.
//
//  A recording is a list of segments, one per uninterrupted stretch. `AVCaptureMovieFileOutput`
//  cannot pause on iOS and cannot change its input mid-file, so pausing ends a segment and
//  resuming — or switching camera — starts the next. `recording()` joins them without
//  re-encoding, for the review while paused and for the send;
//  the one encode is the send's (`MediaManager.videoNoteRender`: the centre 3:4 at 720×960, HEVC,
//  SDR), which also strips metadata.
//
//  The viewfinder shows the centre 3:4 of the same frames (`aspectFill` on a 3:4 view), so what
//  is sent is what was seen.
//

#if os(iOS)
// AVFoundation predates Sendable and does not mark `AVCaptureSession`. Apple asks for
// `startRunning`/`stopRunning` off the main thread, on a serial queue of the app's — `queue` here —
// so handing the session to that queue is the documented use, not a race the warning could catch.
@preconcurrency import AVFoundation
import UIKit

@MainActor
@Observable
final class VideoNoteRecorder: NSObject {
    enum Phase: Equatable {
        case idle
        case recording
        case paused
        case finishing
    }

    enum RecorderError: Error {
        case cameraDenied
        case microphoneDenied
        case noCamera
        case configurationFailed
        case nothingRecorded
    }

    /// The longest note. Longer goes through attachments as an ordinary video.
    static let maxDuration: TimeInterval = 60

    private(set) var phase: Phase = .idle
    private(set) var position: AVCaptureDevice.Position = .front
    /// Recorded time across segments, updated while recording.
    private(set) var elapsed: TimeInterval = 0

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let output = AVCaptureMovieFileOutput()
    @ObservationIgnored private var videoInput: AVCaptureDeviceInput?
    /// Capture work off the main thread, as AVFoundation asks.
    @ObservationIgnored private let queue = DispatchQueue(label: "VideoNoteRecorder.session")

    @ObservationIgnored private var segments: [URL] = []
    /// The segments joined by `recording()`, and how many there were then.
    @ObservationIgnored private var joined: (segments: Int, url: URL)?
    @ObservationIgnored private var finishedDuration: TimeInterval = 0
    @ObservationIgnored private var segmentStart: Date?
    @ObservationIgnored private var ticker: Timer?
    /// Resumed when the segment being written lands on disk.
    @ObservationIgnored private var segmentFinished: CheckedContinuation<Void, Never>?

    // MARK: Lifecycle

    /// Ask for both permissions, configure the session, start the camera and the first segment.
    func start() async throws {
        guard phase == .idle else { return }
        guard await AVCaptureDevice.requestAccess(for: .video) else { throw RecorderError.cameraDenied }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw RecorderError.microphoneDenied }
        try configure()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { [session] in
                session.startRunning()
                done.resume()
            }
        }
        startSegment()
    }

    func pause() async {
        guard phase == .recording else { return }
        await endSegment()
        phase = .paused
    }

    func resume() {
        guard phase == .paused, remaining > 0 else { return }
        startSegment()
    }

    /// Front ↔ back. While recording this ends one segment and starts the next — a few frames
    /// are lost at the cut, which is the price of a single-input output.
    func switchCamera() async {
        let wasRecording = phase == .recording
        if wasRecording { await endSegment() }
        let next: AVCaptureDevice.Position = position == .front ? .back : .front
        if (try? attachCamera(next)) != nil { position = next }
        if wasRecording { startSegment() }
    }

    /// What has been recorded so far, as one file — for the review while paused. Rebuilt only
    /// when a segment has been added since the last call.
    func recording() async throws -> URL {
        if let joined, joined.segments == segments.count { return joined.url }
        if let joined { try? FileManager.default.removeItem(at: joined.url) }
        guard !segments.isEmpty, finishedDuration > 0 else { throw RecorderError.nothingRecorded }
        let url = try await Self.join(segments)
        joined = (segments.count, url)
        return url
    }

    /// Stop, and hand over the recording as one file — the caller owns it from here.
    func finish() async throws -> URL {
        if phase == .recording { await endSegment() }
        phase = .finishing
        stopSession()
        defer {
            joined = nil
            discardSegments()
            phase = .idle
        }
        return try await recording()
    }

    func cancel() async {
        if phase == .recording { await endSegment() }
        stopSession()
        if let joined { try? FileManager.default.removeItem(at: joined.url) }
        joined = nil
        discardSegments()
        phase = .idle
    }

    private var remaining: TimeInterval { Self.maxDuration - finishedDuration }

    // MARK: Session

    private func configure() throws {
        guard session.inputs.isEmpty else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .hd1280x720

        try attachCamera(position, configuring: false)
        guard let mic = AVCaptureDevice.default(for: .audio),
              let micInput = try? AVCaptureDeviceInput(device: mic),
              session.canAddInput(micInput) else { throw RecorderError.configurationFailed }
        session.addInput(micInput)

        // The capture session would set the app's audio session itself, to play-and-record with
        // the earpiece as the output — and the review while paused would then play at a whisper.
        session.automaticallyConfiguresApplicationAudioSession = false
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try audio.setActive(true)

        guard session.canAddOutput(output) else { throw RecorderError.configurationFailed }
        session.addOutput(output)
        // A note never reaches the minute; a fragment is only for crash recovery of long movies.
        output.movieFragmentInterval = .invalid
    }

    private func attachCamera(_ position: AVCaptureDevice.Position, configuring: Bool = true) throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device) else { throw RecorderError.noCamera }
        if configuring { session.beginConfiguration() }
        defer { if configuring { session.commitConfiguration() } }
        if let videoInput { session.removeInput(videoInput) }
        guard session.canAddInput(input) else {
            if let videoInput { session.addInput(videoInput) }
            throw RecorderError.configurationFailed
        }
        session.addInput(input)
        videoInput = input
        if let connection = output.connection(with: .video) {
            // Portrait, written as the track's transform; the send's encode turns it into pixels.
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .auto }
        }
    }

    private func stopSession() {
        ticker?.invalidate()
        ticker = nil
        queue.async { [session] in
            session.stopRunning()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: Segments

    private func startSegment() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("note-\(UUID().uuidString)").appendingPathExtension("mov")
        output.maxRecordedDuration = CMTime(seconds: remaining, preferredTimescale: 600)
        output.startRecording(to: url, recordingDelegate: self)
        segments.append(url)
        segmentStart = Date()
        phase = .recording
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard phase == .recording, let segmentStart else { return }
        elapsed = min(Self.maxDuration, finishedDuration + Date().timeIntervalSince(segmentStart))
    }

    private func endSegment() async {
        ticker?.invalidate()
        ticker = nil
        guard output.isRecording else { return }
        await withCheckedContinuation { continuation in
            segmentFinished = continuation
            output.stopRecording()
        }
    }

    private func discardSegments() {
        for url in segments { try? FileManager.default.removeItem(at: url) }
        segments = []
        finishedDuration = 0
        elapsed = 0
    }

    /// One file from the segments, in order, without re-encoding.
    private static func join(_ segments: [URL]) async throws -> URL {
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw RecorderError.configurationFailed }
        var cursor = CMTime.zero
        for url in segments {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            guard duration > .zero else { continue }
            let range = CMTimeRange(start: .zero, duration: duration)
            if let v = try await asset.loadTracks(withMediaType: .video).first {
                try video.insertTimeRange(range, of: v, at: cursor)
                video.preferredTransform = try await v.load(.preferredTransform)
            }
            if let a = try await asset.loadTracks(withMediaType: .audio).first {
                try audio.insertTimeRange(range, of: a, at: cursor)
            }
            cursor = cursor + duration
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("note-\(UUID().uuidString)").appendingPathExtension("mov")
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw RecorderError.configurationFailed
        }
        try await export.export(to: url, as: .mov)
        return url
    }
}

extension VideoNoteRecorder: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        let recorded = output.recordedDuration.seconds
        Task { @MainActor in
            finishedDuration += recorded.isFinite ? recorded : 0
            elapsed = finishedDuration
            if let continuation = segmentFinished {
                segmentFinished = nil
                continuation.resume()
            } else if phase == .recording {
                // Stopped by the output itself: the minute is up.
                ticker?.invalidate()
                ticker = nil
                phase = .paused
            }
            if let error {
                Log.debug("Video note segment ended: \(error)", category: "VideoNoteRecorder")
            }
        }
    }
}
#endif
