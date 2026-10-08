//
//  IncomingVideoCallView.swift
//  Construct Messenger
//
//  An incoming video call while the app is open: ourselves on the whole screen, as the caller is
//  about to see us, and three answers — decline, without video, answer. CallKit rings too and
//  its banner stays; its one answer button answers with the camera. The screen exists for the
//  middle button (owner, 2026-10-03 and 2026-10-06). `IncomingVideoScreen` decides when it shows.
//

#if os(iOS)
import AVFoundation
import SwiftUI

struct IncomingVideoCallView: View {
    let session: CallSession
    let onAnswer: (_ withCamera: Bool) -> Void
    let onDecline: () -> Void

    @State private var preview = IncomingCameraPreview()

    private enum Layout {
        static let actionSpacing: CGFloat = CTSpace.xxl
        static let actionsBottom: CGFloat = CTSpace.xxl + CTSpace.xl
        static let avatarSize: CGFloat = CTAvatarSize.hero
    }

    var body: some View {
        ZStack {
            Color.CT.bg.ignoresSafeArea()

            if preview.isAvailable {
                CameraPreviewLayerView(session: preview.session)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            } else {
                ContactMainAvatarView(userId: session.peerUserId, displayName: session.peerName, size: Layout.avatarSize)
            }

            VStack(spacing: 0) {
                header
                Spacer()
                actions
                    .padding(.bottom, Layout.actionsBottom)
            }
        }
        .onAppear { preview.start() }
        .onDisappear { preview.stop() }
    }

    private var header: some View {
        VStack(spacing: CTLayout.inlinePad) {
            Text(session.peerName)
                .font(CTFont.title)
                .foregroundStyle(Color.CT.onMedia)
                .lineLimit(1)
            Text(NSLocalizedString("call_incoming_video", comment: ""))
                .font(CTFont.secondary)
                .foregroundStyle(Color.CT.onMediaDim)
        }
        .padding(.top, CTLayout.hitTarget)
        .padding(.bottom, CTLayout.edgePad)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [Color.CT.mediaScrim, .clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        HStack(alignment: .top, spacing: Layout.actionSpacing) {
            action(systemImage: "phone.down.fill", label: "call_decline", background: Color.CT.danger) {
                preview.stop(then: onDecline)
            }
            action(systemImage: "video.slash.fill", label: "call_answer_without_video", background: Color.CT.mediaControl) {
                preview.stop { onAnswer(false) }
            }
            action(systemImage: "video.fill", label: "call_answer", background: Color.CT.answer) {
                preview.stop { onAnswer(true) }
            }
        }
    }

    private func action(systemImage: String, label: String, background: Color, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: CTLayout.inlinePad) {
                Image(systemName: systemImage)
                    .font(CTIcon.font(CTIcon.control))
                    .foregroundStyle(Color.CT.onMedia)
                    .frame(width: CTLayout.callControlSize, height: CTLayout.callControlSize)
                    .background(background, in: Circle())
                Text(NSLocalizedString(label, comment: ""))
                    .font(CTFont.caption)
                    .foregroundStyle(Color.CT.onMedia)
                    .fixedSize()
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

/// Our own camera before the call has a peer connection: a plain capture session behind a
/// preview layer. Never asks for camera access — a ringing phone is no moment for a permission
/// prompt; without access the screen shows the caller's avatar. It stops before the call's own
/// capturer starts, so two sessions never hold the camera at once.
@Observable
final class IncomingCameraPreview: @unchecked Sendable {
    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let queue = DispatchQueue(label: "calls.incoming-preview")
    @ObservationIgnored private var configured = false
    private(set) var isAvailable = false

    func start() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
              let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        else { return }
        isAvailable = true
        queue.async { [self] in
            if !configured {
                session.beginConfiguration()
                if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                    session.addInput(input)
                }
                session.commitConfiguration()
                configured = true
            }
            session.startRunning()
        }
    }

    /// Stops the camera, then runs `then` on the main actor — answering starts the call's
    /// capturer, which must find the camera free.
    func stop(then: @escaping @MainActor () -> Void = {}) {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            Task { @MainActor in then() }
        }
    }
}

private struct CameraPreviewLayerView: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

#Preview("Incoming video call") {
    IncomingVideoCallView(
        session: CallSession(id: "c", uuid: UUID(), peerUserId: "u", peerName: "Kim", direction: .incoming),
        onAnswer: { _ in },
        onDecline: {}
    )
}
#endif
