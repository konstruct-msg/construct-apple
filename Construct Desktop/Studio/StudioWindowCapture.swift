//
//  StudioWindowCapture.swift
//  Construct Desktop
//
//  The host's DAW on screen, for Studio (`decisions/studio-mode-on-desktop.md`, step 5):
//  ScreenCaptureKit filtered to the DAW's own windows — its plug-in windows included, nothing
//  else. Another app's window over the DAW, a notification, the desktop picture: none of them is
//  in the stream. The capture is of the display the DAW's largest window is on, at about 1440p,
//  up to 30 frames a second, with the cursor.
//
//  The first start asks for the system's screen-recording permission; refused, the start
//  throws, and the studio goes on as sound (`CallManager.startStudioScreen`).
//

import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit
import WebRTC

@MainActor
final class StudioWindowCapture: StudioScreenCapture {
    private let bundleIdentifier: String
    private(set) var sourceDescription: String
    private var stream: SCStream?
    private var output: Output?
    private let queue = DispatchQueue(label: "studio.screen.capture", qos: .userInteractive)

    /// The DAW whose windows are shown — the one whose sound is the program.
    static func make() -> any StudioScreenCapture {
        StudioWindowCapture(bundleIdentifier: StudioSource.stored() ?? "")
    }

    init(bundleIdentifier: String) {
        self.bundleIdentifier = bundleIdentifier
        self.sourceDescription = bundleIdentifier
    }

    /// What is captured: the DAW, its windows on screen, and the display its largest one is on.
    struct Target {
        let app: SCRunningApplication
        let windows: [SCWindow]
        let display: SCDisplay
    }

    /// Why there is no target, for the check before a call.
    enum Unavailable: Error, CustomStringConvertible {
        case permissionMissing
        case notRunning(String)
        case noWindow(String)
        case noDisplay

        var description: String {
            switch self {
            case .permissionMissing: "no screen-recording permission"
            case .notRunning(let id): "\(id) is not running"
            case .noWindow(let name): "\(name) has no window on screen"
            case .noDisplay: "no display to capture"
            }
        }
    }

    static func target(bundleIdentifier: String) async throws -> Target {
        // Asked for, not checked first: the first call is what makes the system ask the person.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            if !CGPreflightScreenCaptureAccess() { throw Unavailable.permissionMissing }
            throw error
        }
        guard let app = content.applications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            throw Unavailable.notRunning(bundleIdentifier)
        }
        let windows = content.windows.filter { $0.owningApplication?.bundleIdentifier == bundleIdentifier && $0.isOnScreen }
        guard let main = windows.max(by: { area($0.frame) < area($1.frame) }) else {
            throw Unavailable.noWindow(app.applicationName)
        }
        guard let display = content.displays.max(by: {
            area($0.frame.intersection(main.frame)) < area($1.frame.intersection(main.frame))
        }) else {
            throw Unavailable.noDisplay
        }
        return Target(app: app, windows: windows, display: display)
    }

    func start(into feed: StudioScreenFeed) async throws {
        let target = try await Self.target(bundleIdentifier: bundleIdentifier)
        let (app, windows, display) = (target.app, target.windows, target.display)

        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        let size = StudioScreen.fit(width: Int(filter.contentRect.width * scale), height: Int(filter.contentRect.height * scale))
        let config = SCStreamConfiguration()
        config.width = size.width
        config.height = size.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(StudioScreen.maxFps))
        // What the encoder takes without a conversion.
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.showsCursor = true
        config.queueDepth = 5

        let output = Output(feed: feed)
        let stream = SCStream(filter: filter, configuration: config, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        self.output = output
        sourceDescription = "\(app.applicationName), \(windows.count) windows on display \(display.displayID), \(size.width)×\(size.height)"
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        if let output { Log.info("Studio screen sent: \(output.frames) frames", category: "Calls") }
        output = nil
        Task { try? await stream.stopCapture() }
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }

    /// The stream's frames, on the capture queue, into the screen's section. Only complete
    /// frames: ScreenCaptureKit also sends "idle" ones, with no picture, while nothing changes.
    private final class Output: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
        let feed: StudioScreenFeed
        /// Touched on the capture queue only, read once at the stop.
        private(set) var frames = 0

        init(feed: StudioScreenFeed) { self.feed = feed }

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen, sampleBuffer.isValid,
                  let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                  let status = (attachments.first?[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:)),
                  status == .complete,
                  let pixelBuffer = sampleBuffer.imageBuffer
            else { return }
            let timeNs = Int64(CMTimeGetSeconds(sampleBuffer.presentationTimeStamp) * 1_000_000_000)
            feed.deliver(pixelBuffer, timeNs: timeNs)
            frames += 1
        }

        func stream(_ stream: SCStream, didStopWithError error: Error) {
            Log.error("Studio screen capture stopped: \(error)", category: "Calls")
        }
    }
}
