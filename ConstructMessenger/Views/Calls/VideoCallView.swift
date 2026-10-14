//
//  VideoCallView.swift
//  Construct Messenger
//
//  The call screen while a camera is on. Like FaceTime, only less: one face on the whole screen,
//  ours in a small window, four controls in one glass capsule. Nothing here has to be learned —
//  controls are SF Symbols in the platform's shapes; what is ours is the quiet.
//  `client/specs/VIDEO_CALLS_DESIGN.md`, stage 2. What goes where is `VideoCallStage`.
//

#if os(iOS)
import AVFoundation
import SwiftUI

struct VideoCallView: View {
    let session: CallSession
    let stage: VideoCallStage
    let video: CallVideoState
    /// The timer, or what the call is doing instead ("connecting…", "reconnecting…").
    let status: String
    let quality: CallQuality
    let isConnecting: Bool
    @Binding var isMuted: Bool
    @Binding var swapped: Bool
    var onMuteChanged: (Bool) -> Void
    var onEnd: () -> Void
    var onMinimize: (() -> Void)?
    var onCameraChanged: (Bool) -> Void
    var onSwitchCamera: () -> Void

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var controlsShown = true
    @State private var hideTask: Task<Void, Never>?
    @State private var corner: PreviewCorner = .topTrailing
    @State private var dragOffset: CGSize = .zero

    private enum Layout {
        static let previewWidth: CGFloat = 104
        static let previewHeight: CGFloat = 156
        static let controlSpacing: CGFloat = 14
        static let capsulePadding: CGFloat = 10
        static let capsuleBottom: CGFloat = 42
        /// Room the header and the capsule take, so a window in their corner moves clear of them
        /// while they are shown.
        static let headerClearance: CGFloat = CTLayout.hitTarget + CTLayout.inlinePad * 2
        static let capsuleClearance: CGFloat = CTLayout.callControlSize + capsulePadding * 2 + capsuleBottom
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.CT.bg.ignoresSafeArea()

                pane(stage.big)
                    .id(stage.big)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { toggleControls() }
                    .accessibilityHidden(true)

                if controlsShown {
                    VStack {
                        header
                        Spacer()
                        controls
                            .padding(.bottom, Layout.capsuleBottom)
                    }
                    .transition(.opacity)
                }

                if let small = stage.small {
                    preview(small, in: geo.size)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: controlsShown)
        .animation(.spring(duration: 0.35), value: corner)
        .onAppear { scheduleHide() }
        .onChange(of: stage) { _, _ in scheduleHide() }
        .onChange(of: isConnecting) { _, _ in scheduleHide() }
        .onDisappear { hideTask?.cancel() }
    }

    // MARK: - Panes

    @ViewBuilder
    private func pane(_ pane: VideoCallStage.Pane) -> some View {
        switch pane {
        case .remoteVideo:
            videoView(.remote)
        case .localVideo:
            // The front camera is a mirror, as in every camera app.
            videoView(.local)
                .scaleEffect(x: video.facing == .front ? -1 : 1)
        case .remoteAvatar:
            ZStack {
                Color.CT.bg
                VStack(spacing: CTLayout.edgePad) {
                    ContactMainAvatarView(userId: session.peerUserId, displayName: session.peerName, size: CTAvatarSize.hero)
                    Image(systemName: "video.slash.fill")
                        .font(CTIcon.font(CTIcon.row))
                        .foregroundStyle(Color.CT.textDim)
                        .accessibilityLabel(NSLocalizedString("call_peer_camera_off", comment: ""))
                }
            }
        case .localCameraOff:
            ZStack {
                Color.CT.bgMsg
                Image(systemName: "video.slash.fill")
                    .font(CTIcon.font(CTIcon.control))
                    .foregroundStyle(Color.CT.textDim)
            }
        }
    }

    @ViewBuilder
    private func videoView(_ side: CallVideoSide) -> some View {
        #if canImport(WebRTC)
        CallVideoView(side: side)
        #else
        Color.black
        #endif
    }

    private func preview(_ pane: VideoCallStage.Pane, in size: CGSize) -> some View {
        let reservedTop = controlsShown && corner.isTop ? Layout.headerClearance : 0
        let reservedBottom = controlsShown && !corner.isTop ? Layout.capsuleClearance : 0
        return self.pane(pane)
            .id(pane)
            .frame(width: Layout.previewWidth, height: Layout.previewHeight)
            .clipShape(CTShape.card())
            .overlay(CTShape.card().stroke(Color.CT.mediaControl, lineWidth: 1))
            .shadow(color: Color.CT.mediaScrim, radius: 12, y: 6)
            .offset(dragOffset)
            .gesture(
                DragGesture()
                    .onChanged { dragOffset = $0.translation }
                    .onEnded { value in
                        // Where the flick was going, not where the finger stopped.
                        let origin = cornerOrigin(in: size)
                        let landing = CGPoint(
                            x: origin.x + value.predictedEndTranslation.width,
                            y: origin.y + value.predictedEndTranslation.height
                        )
                        corner = PreviewCorner.nearest(to: landing, in: size)
                        dragOffset = .zero
                    }
            )
            .onTapGesture {
                guard stage.canSwap else { return }
                swapped.toggle()
            }
            .accessibilityElement()
            .accessibilityLabel(NSLocalizedString(
                stage.canSwap ? "call_swap_video" : "call_self_view", comment: ""
            ))
            .accessibilityAddTraits(stage.canSwap ? .isButton : [])
            .padding(.horizontal, CTLayout.edgePad)
            .padding(.top, CTLayout.inlinePad + reservedTop)
            .padding(.bottom, reservedBottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
    }

    /// The centre of the window at its corner, in the screen's coordinates.
    private func cornerOrigin(in size: CGSize) -> CGPoint {
        let inset = CTLayout.edgePad
        let x = corner == .topLeading || corner == .bottomLeading
            ? inset + Layout.previewWidth / 2
            : size.width - inset - Layout.previewWidth / 2
        let y = corner.isTop
            ? inset + Layout.previewHeight / 2
            : size.height - inset - Layout.previewHeight / 2
        return CGPoint(x: x, y: y)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: CTLayout.edgePad) {
            if let onMinimize {
                Button(action: onMinimize) {
                    Image(systemName: "chevron.down")
                        .font(CTIcon.font(CTIcon.navLg))
                        .foregroundStyle(Color.CT.onMedia)
                        .frame(width: CTLayout.hitTarget, height: CTLayout.hitTarget)
                        .glassCapsule()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("call_minimize", comment: ""))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(session.peerName)
                    .font(CTFont.title)
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill")
                        .font(CTIcon.font(CTIcon.caption))
                        .accessibilityLabel(NSLocalizedString("call_e2ee_badge", comment: ""))
                    Text(status)
                        .font(CTFont.mono(13))
                    if quality == .reconnecting {
                        Image(systemName: "wifi.exclamationmark")
                            .font(CTIcon.font(CTIcon.caption))
                            .accessibilityLabel(NSLocalizedString("call_reconnecting", comment: ""))
                    }
                }
            }
            .foregroundStyle(Color.CT.onMedia)
            .shadow(color: Color.CT.mediaScrim, radius: 6, y: 1)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, CTLayout.edgePad)
        .padding(.top, CTLayout.inlinePad)
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: Layout.controlSpacing) {
            control(
                systemImage: isMuted ? "mic.slash.fill" : "mic.fill",
                label: NSLocalizedString(isMuted ? "call_unmute" : "call_mute", comment: ""),
                isOff: isMuted
            ) {
                isMuted.toggle()
                onMuteChanged(isMuted)
            }
            control(
                systemImage: video.localCameraOn ? "video.fill" : "video.slash.fill",
                label: NSLocalizedString("call_camera", comment: ""),
                isOff: !video.localCameraOn
            ) {
                onCameraChanged(!video.localCameraOn)
            }
            if video.localCameraOn {
                control(
                    systemImage: "arrow.triangle.2.circlepath.camera",
                    label: NSLocalizedString("call_flip_camera", comment: ""),
                    isOff: false,
                    action: onSwitchCamera
                )
            }
            VideoCallRouteButton()
            Button(action: onEnd) {
                Image(systemName: "phone.down.fill")
                    .font(CTIcon.font(CTIcon.control))
                    .foregroundStyle(.white)
                    .frame(width: CTLayout.callControlSize, height: CTLayout.callControlSize)
                    .background(Color.CT.danger, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("call_end", comment: ""))
        }
        .padding(Layout.capsulePadding)
        .glassCapsule()
        // A touch on the capsule is a touch: it restarts the countdown instead of letting the
        // controls vanish under the finger.
        .simultaneousGesture(TapGesture().onEnded { scheduleHide() })
    }

    /// A round control. Off — muted, camera off — is the filled, inverted state, as in FaceTime:
    /// the thing that is unusual is the thing that stands out.
    private func control(systemImage: String, label: String, isOff: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(CTIcon.font(CTIcon.control))
                .foregroundStyle(isOff ? Color.black : Color.CT.onMedia)
                .frame(width: CTLayout.callControlSize, height: CTLayout.callControlSize)
                .background(isOff ? Color.CT.mediaControlOn : Color.CT.mediaControl, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOff ? .isSelected : [])
    }

    // MARK: - Hiding

    private func toggleControls() {
        controlsShown.toggle()
        if controlsShown { scheduleHide() } else { hideTask?.cancel() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard stage.controlsAutoHide(isConnecting: isConnecting, voiceOver: voiceOver) else {
            controlsShown = true
            return
        }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: VideoCallStage.controlsHideAfter)
            guard !Task.isCancelled else { return }
            controlsShown = false
        }
    }
}

/// The audio route, in the capsule only when there is a choice to make — a headset, Bluetooth,
/// AirPlay. Otherwise a video call is on the speaker and there is nothing to pick.
private struct VideoCallRouteButton: View {
    @State private var hasChoice = false

    var body: some View {
        Group {
            if hasChoice {
                ZStack {
                    Image(systemName: "airplayaudio")
                        .font(CTIcon.font(CTIcon.control))
                        .foregroundStyle(Color.CT.onMedia)
                        .frame(width: CTLayout.callControlSize, height: CTLayout.callControlSize)
                        .background(Color.CT.mediaControl, in: Circle())
                    AVRoutePickerViewRepresentable()
                        .frame(width: CTLayout.callControlSize, height: CTLayout.callControlSize)
                        .opacity(0.02) // non-zero, or the picker stops taking taps
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(NSLocalizedString("call_audio_route", comment: ""))
                .accessibilityAddTraits(.isButton)
            }
        }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).receive(on: RunLoop.main)) { _ in
            refresh()
        }
    }

    private func refresh() {
        let session = AVAudioSession.sharedInstance()
        hasChoice = CallAudioRouteControl.control(
            outputs: session.currentRoute.outputs.map(\.portType),
            availableInputs: (session.availableInputs ?? []).map(\.portType)
        ) == .routePicker
    }
}

/// No camera and no peer in a preview, so the video panes are black; the layout, the header, the
/// capsule and the avatar state are what there is to look at.
private struct VideoCallPreview: View {
    let stage: VideoCallStage
    let video: CallVideoState
    @State private var muted = false
    @State private var swapped = false

    var body: some View {
        VideoCallView(
            session: CallSession(id: "p", uuid: UUID(), peerUserId: "user_preview", peerName: "Анна", direction: .outgoing),
            stage: stage, video: video, status: "04:12", quality: .good, isConnecting: false,
            isMuted: $muted, swapped: $swapped,
            onMuteChanged: { _ in }, onEnd: {}, onMinimize: {}, onCameraChanged: { _ in }, onSwitchCamera: {}
        )
    }
}

#Preview("Both cameras") {
    VideoCallPreview(
        stage: VideoCallStage(big: .remoteVideo, small: .localVideo),
        video: CallVideoState(canSend: true, localCameraOn: true, remoteCameraOn: true)
    )
}

#Preview("Their camera off") {
    VideoCallPreview(
        stage: VideoCallStage(big: .remoteAvatar, small: .localVideo),
        video: CallVideoState(canSend: true, localCameraOn: true, remoteCameraOn: false)
    )
}

#Preview("Our camera off") {
    VideoCallPreview(
        stage: VideoCallStage(big: .remoteVideo, small: .localCameraOff),
        video: CallVideoState(canSend: true, localCameraOn: false, remoteCameraOn: true)
    )
}
#endif
