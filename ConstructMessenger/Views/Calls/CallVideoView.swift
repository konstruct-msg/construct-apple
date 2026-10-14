//
//  CallVideoView.swift
//  Construct Messenger
//
//  One side of a video call, drawn by WebRTC's Metal renderer. The view only attaches a track; whether
//  it is on screen at all is `CallVideoState`'s decision, made by the caller of this view.
//

#if os(iOS) && canImport(WebRTC)
import SwiftUI
import WebRTC

struct CallVideoView: UIViewRepresentable {
    let side: CallVideoSide

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFill
        view.clipsToBounds = true
        context.coordinator.attach(track(), to: view)
        return view
    }

    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        context.coordinator.attach(track(), to: view)
    }

    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.attach(nil, to: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func track() -> RTCVideoTrack? {
        guard let session = CallManager.shared.activeWebRTC as? WebRTCSession else { return nil }
        switch side {
        case .local: return session.localVideoTrack
        case .remote: return session.remoteVideoTrack
        }
    }

    /// A track holds its renderers strongly and keeps feeding them, so the one attached is
    /// remembered and taken off before another goes on — or the view is fed by two calls.
    final class Coordinator {
        private var attached: RTCVideoTrack?

        func attach(_ track: RTCVideoTrack?, to view: RTCMTLVideoView) {
            guard track !== attached else { return }
            attached?.remove(view)
            track?.add(view)
            attached = track
        }
    }
}
#endif
