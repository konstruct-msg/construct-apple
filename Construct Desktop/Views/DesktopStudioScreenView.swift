//
//  DesktopStudioScreenView.swift
//  Construct Desktop
//
//  Guest: the host's DAW windows, in a window of their own, opened when the host's screen is
//  shown and closed when it is hidden or the studio ends (`StudioScreenPresenter`). Each frame
//  is already held for the program's buffer depth by the time it gets here.
//

import SwiftUI
import WebRTC

struct DesktopStudioScreenView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    private let presenter = StudioScreenPresenter.shared

    var body: some View {
        ZStack {
            Color.CT.mediaGround
            if let renderer = presenter.renderer {
                StudioScreenVideoView(renderer: renderer)
                    .aspectRatio(presenter.frameSize ?? CGSize(width: 16, height: 9), contentMode: .fit)
            } else {
                Text(NSLocalizedString("studio_screen_waiting", comment: ""))
                    .font(CTFont.body)
                    .foregroundStyle(Color.CT.onMediaDim)
            }
        }
        .ignoresSafeArea()
        .onChange(of: presenter.renderer == nil) { _, gone in
            if gone { dismissWindow() }
        }
    }
}

/// WebRTC's Metal view, fed by the renderer while it is on screen. On macOS the webrtc-sdk build
/// ships `RTCMTLVideoView` as an `NSView`; its `RTCMTLNSVideoView` header has no class behind it.
private struct StudioScreenVideoView: NSViewRepresentable {
    let renderer: StudioScreenRenderer

    func makeNSView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        context.coordinator.attach(renderer, to: view)
        return view
    }

    func updateNSView(_ view: RTCMTLVideoView, context: Context) {
        context.coordinator.attach(renderer, to: view)
    }

    static func dismantleNSView(_ view: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.attach(nil, to: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// The renderer feeding the view, taken off before another goes on.
    final class Coordinator {
        private var attached: StudioScreenRenderer?

        func attach(_ renderer: StudioScreenRenderer?, to view: RTCMTLVideoView) {
            guard renderer !== attached else { return }
            attached?.show(on: nil)
            renderer?.show(on: view)
            attached = renderer
        }
    }
}
