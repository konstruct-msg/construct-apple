//
//  StudioCheckModel.swift
//  Construct Desktop
//
//  The check before a call (`StudioCheck`): the same process tap and window capture a studio
//  uses, run on this Mac alone — the tap into a meter instead of the encoder, the windows into a
//  small preview instead of the call — and the talkback microphone's level. Nothing is sent.
//  Runs while the check window is open and no call is live: a call's microphone and the check's
//  would contend for the same input.
//

import AVFoundation
import AppKit
import CoreImage
import CoreMedia
import ScreenCaptureKit
import Synchronization

@MainActor
@Observable
final class StudioCheckModel {
    static let shared = StudioCheckModel()

    private(set) var capture: StudioCheckCapture = .notStarted
    private(set) var screen: StudioCheckScreen = .notStarted
    private(set) var preview: CGImage?
    /// The program's peaks in dBFS, refreshed while the check runs.
    private(set) var left: Float = StudioMeter.floorDB
    private(set) var right: Float = StudioMeter.floorDB
    /// The talkback microphone's level, 0…1.
    private(set) var microphone: Double = 0
    private(set) var microphoneAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    private(set) var running = false

    private var tap: StudioProcessTap?
    private let meter = MeterBox()
    private var screenPreview: ScreenPreview?
    private var microphoneMeter: MicrophoneMeter?
    private var refresh: Task<Void, Never>?

    private init() {}

    func findings(source: StudioSource?, sendsScreen: Bool) -> [StudioCheckFinding] {
        StudioCheck.findings(source: source, capture: capture, screen: screen,
                             sendsScreen: sendsScreen, microphoneAllowed: microphoneAllowed)
    }

    /// Start, or start over with what is chosen now.
    func start(source: StudioSource?, sendsScreen: Bool) {
        stop()
        running = true
        startMicrophone()
        if let source {
            startProgram(source)
            if sendsScreen { startScreen(source) }
        }
        refresh = Task { [weak self] in
            while !Task.isCancelled {
                self?.pullMeter()
                try? await Task.sleep(for: .milliseconds(66))
            }
        }
    }

    func stop() {
        refresh?.cancel()
        refresh = nil
        tap?.stop()
        tap = nil
        screenPreview?.stop()
        screenPreview = nil
        microphoneMeter?.stop()
        microphoneMeter = nil
        capture = .notStarted
        screen = .notStarted
        preview = nil
        left = StudioMeter.floorDB
        right = StudioMeter.floorDB
        microphone = 0
        running = false
    }

    func resetClip() {
        meter.value.withLock { $0.resetClip() }
        pullMeter()
    }

    func requestMicrophone() {
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            microphoneAllowed = granted
            if granted, running, microphoneMeter == nil { startMicrophone() }
        }
    }

    // MARK: - Program

    private func startProgram(_ source: StudioSource) {
        meter.value.withLock { $0 = StudioMeter() }
        do {
            let tap = try StudioProcessTap(bundleIdentifier: source.bundleID)
            let box = meter
            let packetizer = StudioCapturePacketizer(format: .lossless) { samples, _ in
                box.value.withLock { $0.ingest(samples) }
            }
            try tap.start(into: packetizer)
            self.tap = tap
            capture = .running(StudioMeter())
            Log.info("Studio check: capturing \(tap.sourceDescription)", category: "Calls")
        } catch let failure as StudioProcessTap.Failure {
            Log.error("Studio check: program not captured: \(failure)", category: "Calls")
            capture = .failed(failure.finding)
        } catch {
            Log.error("Studio check: program not captured: \(error)", category: "Calls")
            capture = .failed(.captureFailed)
        }
    }

    private func pullMeter() {
        if let microphoneMeter { microphone = microphoneMeter.level }
        guard case .running = capture else { return }
        let (state, peaks) = meter.value.withLock { meter -> (StudioMeter, (left: Float, right: Float)) in
            let peaks = meter.takePeaks()
            return (meter, peaks)
        }
        capture = .running(state)
        // A meter falls back slowly and jumps up at once, as a peak meter does.
        left = max(peaks.left, left - 1.5)
        right = max(peaks.right, right - 1.5)
    }

    // MARK: - Screen

    private func startScreen(_ source: StudioSource) {
        let preview = ScreenPreview { [weak self] image in self?.preview = image }
        screenPreview = preview
        Task { [weak self] in
            do {
                try await preview.start(bundleIdentifier: source.bundleID)
                guard let self, self.screenPreview === preview else { return }
                self.screen = .showing
            } catch let unavailable as StudioWindowCapture.Unavailable {
                Log.error("Studio check: screen not captured: \(unavailable)", category: "Calls")
                guard let self, self.screenPreview === preview else { return }
                switch unavailable {
                case .permissionMissing: self.screen = .permissionMissing
                case .noWindow, .notRunning: self.screen = .noWindow
                case .noDisplay: self.screen = .failed
                }
            } catch {
                Log.error("Studio check: screen not captured: \(error)", category: "Calls")
                guard let self, self.screenPreview === preview else { return }
                self.screen = .failed
            }
        }
    }

    // MARK: - Microphone

    private func startMicrophone() {
        microphoneAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        guard microphoneAllowed else { return }
        do {
            microphoneMeter = try MicrophoneMeter(uid: WebRTCAudioDevices.selectedInput)
        } catch {
            Log.error("Studio check: microphone not opened: \(error)", category: "Calls")
        }
    }
}

/// The meter, written on the tap's queue and read on the main actor.
private final class MeterBox: Sendable {
    let value = Mutex(StudioMeter())
}

/// The DAW's windows, small and slow — enough to see what the other side will see.
@MainActor
private final class ScreenPreview {
    private var stream: SCStream?
    private var output: Output?
    private let onImage: @MainActor (CGImage) -> Void
    private let queue = DispatchQueue(label: "studio.check.screen", qos: .userInitiated)

    init(onImage: @escaping @MainActor (CGImage) -> Void) { self.onImage = onImage }

    func start(bundleIdentifier: String) async throws {
        let target = try await StudioWindowCapture.target(bundleIdentifier: bundleIdentifier)
        let filter = SCContentFilter(display: target.display, including: [target.app], exceptingWindows: [])
        let config = SCStreamConfiguration()
        let scale = min(1, 960 / max(1, filter.contentRect.width))
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 5)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        let output = Output(onImage: onImage)
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        self.output = output
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        output = nil
        Task { try? await stream.stopCapture() }
    }

    private final class Output: NSObject, SCStreamOutput, @unchecked Sendable {
        private let onImage: @MainActor (CGImage) -> Void
        private let context = CIContext()

        init(onImage: @escaping @MainActor (CGImage) -> Void) { self.onImage = onImage }

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen, sampleBuffer.isValid, let pixelBuffer = sampleBuffer.imageBuffer else { return }
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            guard let cgImage = context.createCGImage(image, from: image.extent) else { return }
            nonisolated(unsafe) let sent = cgImage
            DispatchQueue.main.async { [onImage] in MainActor.assumeIsolated { onImage(sent) } }
        }
    }
}

/// The talkback input's level, from the system's own metering of a capture session.
@MainActor
private final class MicrophoneMeter {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let sink = Sink()
    private let queue = DispatchQueue(label: "studio.check.microphone")

    /// The call's chosen input, or the system's.
    init(uid: String?) throws {
        let device = uid.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .audio)
        guard let device else { throw Failure(description: "no input device") }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw Failure(description: "the session takes no \(device.localizedName)")
        }
        session.addInput(input)
        output.setSampleBufferDelegate(sink, queue: queue)
        session.addOutput(output)
        nonisolated(unsafe) let session = session
        queue.async { session.startRunning() }
    }

    /// 0…1 over −60…0 dB.
    var level: Double {
        guard let channels = output.connections.first?.audioChannels, !channels.isEmpty else { return 0 }
        let peak = channels.map(\.peakHoldLevel).max() ?? StudioMeter.floorDB
        return StudioMeter.fill(peak)
    }

    func stop() {
        nonisolated(unsafe) let session = session
        queue.async { session.stopRunning() }
    }

    /// Takes the buffers so the session meters them; the samples themselves are not used.
    private final class Sink: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {}
}
