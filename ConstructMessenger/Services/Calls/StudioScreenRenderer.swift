//
//  StudioScreenRenderer.swift
//  Construct Messenger
//
//  Guest: the host's DAW windows, each frame shown as long after it arrived as the program waits
//  in its buffer (`decisions/studio-mode-on-desktop.md`, step 5) — so the transport cursor moves
//  with the sound rather than a buffer's depth ahead of it. WebRTC's own jitter buffer cannot be
//  told a target from the Objective-C API, so the hold is here, between the track and the view.
//

#if canImport(WebRTC)
import Foundation
import Observation
import WebRTC

/// Attached to the host's screen track; forwards each frame to `view` once it is due.
/// `renderFrame` is called on WebRTC's decoding thread, the release of due frames runs on a
/// queue of its own, and neither touches the main actor.
final class StudioScreenRenderer: NSObject, RTCVideoRenderer, @unchecked Sendable {
    let delay: Double
    /// One lock for the state below: frames and renderers are WebRTC's classes, which a `Mutex`
    /// will not hold across threads.
    private let lock = NSLock()
    private var frames: StudioScreenDelay<RTCVideoFrame>
    private var view: (any RTCVideoRenderer)?
    private var size: CGSize?
    private var arrived = 0
    private var shown = 0
    private let now: @Sendable () -> Double
    private let queue = DispatchQueue(label: "studio.screen", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    /// How often due frames are looked for: four times the top frame rate, so a frame waits at
    /// most a few milliseconds past its time.
    private static let tick: DispatchTimeInterval = .microseconds(1_000_000 / (StudioScreen.maxFps * 4))

    init(delay: Double, now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.delay = delay
        self.frames = StudioScreenDelay(delay: delay)
        self.now = now
        super.init()
    }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.tick, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.release() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        let (arrived, shown) = lock.withLock { (self.arrived, self.shown) }
        Log.info("Studio screen received: \(arrived) frames, \(shown) shown (held \(Int(delay * 1_000)) ms)", category: "Calls")
    }

    /// Where due frames go: the window's video view, or nil while it is closed.
    func show(on renderer: (any RTCVideoRenderer)?) {
        let size = lock.withLock { () -> CGSize? in
            view = renderer
            return self.size
        }
        if let renderer, let size { Self.setSize(size, on: renderer) }
    }

    // MARK: RTCVideoRenderer

    func setSize(_ size: CGSize) {
        let renderer = lock.withLock { () -> (any RTCVideoRenderer)? in
            self.size = size
            return view
        }
        if let renderer { Self.setSize(size, on: renderer) }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { StudioScreenPresenter.shared.sized(size, for: self) }
        }
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        let arrivedAt = now()
        lock.withLock {
            frames.arrive(frame, at: arrivedAt)
            arrived += 1
        }
    }

    /// Hands the frame that is due to the view; the frames it overtook are dropped.
    func release() {
        let at = now()
        let (frame, renderer) = lock.withLock { () -> (RTCVideoFrame?, (any RTCVideoRenderer)?) in
            guard let frame = frames.due(at: at) else { return (nil, nil) }
            shown += 1
            return (frame, view)
        }
        if let frame { renderer?.renderFrame(frame) }
    }

    /// A view's size is set on the main thread; a frame is not.
    private static func setSize(_ size: CGSize, on renderer: any RTCVideoRenderer) {
        nonisolated(unsafe) let renderer = renderer
        DispatchQueue.main.async { renderer.setSize(size) }
    }
}

/// The host's screen while a guest is shown it — what the Desktop watches to open and close the
/// screen's window. `ActiveCall` is not observed, so this is set apart.
@MainActor
@Observable
final class StudioScreenPresenter {
    static let shared = StudioScreenPresenter()

    private(set) var renderer: StudioScreenRenderer?
    /// The host's frames' size, for the window's aspect; nil until the first frame.
    private(set) var frameSize: CGSize?

    func show(_ renderer: StudioScreenRenderer) {
        self.renderer = renderer
        frameSize = nil
    }

    /// Only the renderer shown: one ended late does not take down its successor's window.
    func hide(_ renderer: StudioScreenRenderer) {
        guard self.renderer === renderer else { return }
        self.renderer = nil
        frameSize = nil
    }

    func sized(_ size: CGSize, for renderer: StudioScreenRenderer) {
        guard self.renderer === renderer, size.width > 0, size.height > 0 else { return }
        frameSize = size
    }
}
#endif
