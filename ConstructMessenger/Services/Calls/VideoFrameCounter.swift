//
//  VideoFrameCounter.swift
//  Construct Messenger
//
//  Whether video frames actually flow — the one thing the call log could not say. A call can
//  negotiate a video sender, announce the camera on, and still send nothing: the capture session
//  stopped, was interrupted, or never delivered. On 2026-10-05 the owner reported "the caller's
//  camera does not come on" and the log showed every step succeed. This counts frames on both
//  ends and says so: the first one, then a line every few seconds, and a line when they stop.
//

#if os(iOS) && canImport(WebRTC)
import AVFoundation
import Foundation
import os
import WebRTC

/// Counts frames passing through, as a capturer's delegate (forwarding to the video source) or
/// as a renderer on a received track. Called on WebRTC's threads.
final class VideoFrameCounter: NSObject, RTCVideoCapturerDelegate, RTCVideoRenderer, @unchecked Sendable {
    private let label: String
    /// Where captured frames go on to. Nil for a renderer, which only watches.
    private weak var forward: RTCVideoSource?
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var total = 0
        var sinceReport = 0
        var lastReport: Date?
        var size = ""
    }

    private static let reportEvery: TimeInterval = 5

    init(label: String, forwardingTo source: RTCVideoSource? = nil) {
        self.label = label
        self.forward = source
    }

    // RTCVideoCapturerDelegate
    func capturer(_ capturer: RTCVideoCapturer, didCapture frame: RTCVideoFrame) {
        forward?.capturer(capturer, didCapture: frame)
        count(frame)
    }

    // RTCVideoRenderer
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        count(frame)
    }

    private func count(_ frame: RTCVideoFrame) {
        let now = Date()
        let line: String? = state.withLock { s in
            s.total += 1
            s.sinceReport += 1
            s.size = "\(frame.width)x\(frame.height)"
            guard let last = s.lastReport else {
                s.lastReport = now
                s.sinceReport = 0
                return "first frame \(s.size)"
            }
            guard now.timeIntervalSince(last) >= Self.reportEvery else { return nil }
            let rate = Double(s.sinceReport) / now.timeIntervalSince(last)
            s.lastReport = now
            s.sinceReport = 0
            return String(format: "%.1f fps, %d total, %@", rate, s.total, s.size)
        }
        if let line { Log.info("VIDEO[\(label)] \(line)", category: "Calls") }
    }

    /// Said when the camera stops or the call ends, so a log shows how many frames there were.
    func summary() -> String {
        state.withLock { "VIDEO[\(label)] \($0.total) frames\($0.total == 0 ? " — none arrived" : "")" }
    }
}

/// Logs what happens to a capture session that WebRTC does not tell us: interruptions (another
/// app, the system, a call) and runtime errors. A capturer that stops this way stops silently.
final class CaptureSessionWatcher {
    private var tokens: [NSObjectProtocol] = []

    init(session: AVCaptureSession, label: String) {
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { note in
            let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int ?? -1
            Log.error("VIDEO[\(label)] capture interrupted, reason=\(raw) (\(Self.reasonName(raw)))", category: "Calls")
        })
        tokens.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { _ in
            Log.info("VIDEO[\(label)] capture interruption ended", category: "Calls")
        })
        tokens.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            Log.error("VIDEO[\(label)] capture runtime error: \(error.map { "\($0.domain) \($0.code) \($0.localizedDescription)" } ?? "unknown")", category: "Calls")
        })
    }

    deinit {
        tokens.forEach(NotificationCenter.default.removeObserver)
    }

    private static func reasonName(_ raw: Int) -> String {
        switch AVCaptureSession.InterruptionReason(rawValue: raw) {
        case .videoDeviceNotAvailableInBackground: return "in background"
        case .audioDeviceInUseByAnotherClient: return "audio device in use"
        case .videoDeviceInUseByAnotherClient: return "camera in use by another client"
        case .videoDeviceNotAvailableWithMultipleForegroundApps: return "multiple foreground apps"
        case .videoDeviceNotAvailableDueToSystemPressure: return "system pressure"
        default: return "other"
        }
    }
}
#endif
