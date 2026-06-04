//
//  InCallView.swift
//  Construct Messenger
//
//  Full-screen active-call overlay.
//  Japanese minimalism: one focal point (avatar), one action row.
//

import SwiftUI
#if os(iOS)
import AVKit
import AVFoundation
#endif

struct InCallView: View {
    let session: CallManager.CallSession
    let isConnecting: Bool
    var endReason: CallManager.EndReason? = nil
    /// Coarse network health for the active call. `.reconnecting` makes the
    /// pulse re-appear around the avatar and overrides the status text with a
    /// "reconnecting…" hint. `.good` is the calm baseline.
    var quality: CallQuality = .good
    /// Optional minimise handler. When non-nil, a chevron-down button appears
    /// in the top-left and tapping it asks the host to dismiss the full-screen
    /// cover without ending the call. `MainTabView` then shows a top-of-screen
    /// `InCallMiniBar` and lets the user keep using the rest of the app.
    var onMinimize: (() -> Void)? = nil

    @State private var isMuted = false
    @State private var elapsed: Int = 0
    @State private var timer: Timer? = nil

    private var isEnded: Bool { endReason != nil }

    var body: some View {
        ZStack {
            Color.CT.bg
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Minimise button — chevron-down in the top-left. Hidden once
                // the call enters its ended-state, since the screen is about
                // to auto-dismiss anyway.
                HStack {
                    if let onMinimize, !isEnded {
                        Button(action: onMinimize) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(Color.CT.textDim)
                                .frame(width: 44, height: 44, alignment: .leading)
                        }
                        .accessibilityLabel(NSLocalizedString("call_minimize", comment: ""))
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)

                Spacer()

                // Avatar + name
                VStack(spacing: 16) {
                    ZStack {
                        MainAvatarView(userId: session.peerUserId, displayName: session.peerName, size: 96)
                        // Pulse appears in two distinct UX moments:
                        // 1. While the call is dialling / ringing (connecting=true)
                        // 2. While ICE has transiently dropped (.reconnecting)
                        // Static avatar otherwise = "everything's fine".
                        if !isEnded && (isConnecting || quality == .reconnecting) {
                            PulseRingView(size: 96)
                        }
                    }

                    Text(session.peerName)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.CT.text)

                    Text(statusText)
                        .font(CTFont.regular(14))
                        .foregroundStyle(isEnded ? Color.CT.danger.opacity(0.85) : Color.CT.textDim)
                        .animation(.easeInOut(duration: 0.3), value: isConnecting)

                    // E2EE trust signal. Always shown while the call is live;
                    // hidden on `.ended` since the channel is gone.
                    if !isEnded {
                        HStack(spacing: 4) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 10, weight: .medium))
                            Text(NSLocalizedString("call_e2ee_badge", comment: ""))
                                .font(CTFont.regular(11))
                        }
                        .foregroundStyle(Color.CT.textDim)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.CT.bgMsg)
                        .clipShape(Capsule())
                        .accessibilityLabel(NSLocalizedString("call_e2ee_badge", comment: ""))
                    }
                }

                Spacer()
                Spacer()

                // Controls only while the call is active. On `.ended` we show
                // just the avatar + status text and let `endedAutoClearDelay`
                // dismiss the full-screen cover — FaceTime-style.
                if !isEnded {
                    CallControlsBar(onEnd: { CallManager.shared.endCall() }) {
                        CallControlButton(config: muteConfig)
                        #if os(iOS)
                        AudioRoutePickerButton()
                        #endif
                    }
                    .padding(.bottom, 52)
                }
            }
        }
        .onAppear {
            guard !isConnecting && !isEnded else { return }
            startTimer()
        }
        .onChange(of: isConnecting) { _, connecting in
            if !connecting && !isEnded { startTimer() } else { stopTimer() }
        }
        .onChange(of: isEnded) { _, ended in
            if ended { stopTimer() }
        }
        .onDisappear { stopTimer() }
    }

    // MARK: - Secondary controls

    private var muteConfig: CallControlConfig {
        CallControlConfig(
            systemImage: isMuted ? "mic.slash.fill" : "mic.fill",
            label: NSLocalizedString(isMuted ? "call_unmute" : "call_mute", comment: ""),
            tint: isMuted ? Color.CT.accent : Color.CT.textDim,
            action: {
                isMuted.toggle()
                CallManager.shared.setMuted(isMuted)
            }
        )
    }

    // MARK: - Status text

    private var statusText: String {
        if let reason = endReason {
            switch reason {
            case .hangup(let r):
                switch r {
                case .normal: return NSLocalizedString("call_ended", comment: "")
                case .declined: return NSLocalizedString("call_declined", comment: "")
                case .busy: return NSLocalizedString("call_busy", comment: "")
                case .timeout: return NSLocalizedString("call_missed", comment: "")
                default: return NSLocalizedString("call_ended", comment: "")
                }
            case .local(let msg):
                if msg.contains("TURN") { return NSLocalizedString("call_no_relay", comment: "") }
                return NSLocalizedString("call_failed", comment: "")
            case .error(_):
                return NSLocalizedString("call_failed", comment: "")
            }
        }
        if isConnecting {
            return NSLocalizedString("call_connecting", comment: "")
        }
        if quality == .reconnecting {
            return NSLocalizedString("call_reconnecting", comment: "")
        }
        return formattedElapsed
    }

    // MARK: - Timer

    private var formattedElapsed: String {
        let m = elapsed / 60
        let s = elapsed % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            elapsed += 1
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Pulse ring animation

private struct PulseRingView: View {
    let size: CGFloat
    @State private var scale: CGFloat = 1
    @State private var opacity: Double = 0.5

    var body: some View {
        Circle()
            .stroke(Color.CT.accent.opacity(opacity), lineWidth: 2)
            .scaleEffect(scale)
            .frame(width: size, height: size)
            .onAppear {
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                    scale = 1.5
                    opacity = 0
                }
            }
    }
}

// MARK: - Controls bar

/// FaceTime-style two-row layout: secondary actions on top, prominent End call
/// below. `secondary` uses `@ViewBuilder` so future video calls can mix simple
/// SF-Symbol buttons (`CallControlButton`) with special widgets like the system
/// route picker without reshaping the layout.
private struct CallControlsBar<Secondary: View>: View {
    let onEnd: () -> Void
    @ViewBuilder var secondary: Secondary

    init(onEnd: @escaping () -> Void, @ViewBuilder secondary: () -> Secondary) {
        self.onEnd = onEnd
        self.secondary = secondary()
    }

    var body: some View {
        VStack(spacing: 28) {
            HStack(spacing: 36) {
                secondary
            }

            Button(action: onEnd) {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: CTLayout.callIconSize, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(Color.CT.danger)
                    .clipShape(Circle())
            }
            .accessibilityLabel(NSLocalizedString("call_end", comment: ""))
        }
    }
}

/// Description of a simple secondary call action (SF Symbol + tap handler).
struct CallControlConfig {
    let systemImage: String
    let label: String
    let tint: Color
    let action: () -> Void
}

struct CallControlButton: View {
    let config: CallControlConfig

    var body: some View {
        Button(action: config.action) {
            VStack(spacing: 6) {
                Image(systemName: config.systemImage)
                    .font(.system(size: CTLayout.callIconSize, weight: .medium))
                    .foregroundStyle(config.tint)
                    .frame(width: 56, height: 56)
                    .background(Color.CT.bgMsg)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(config.tint.opacity(0.4), lineWidth: 1))
                Text(config.label)
                    .font(CTFont.regular(10))
                    .foregroundStyle(Color.CT.textDim)
            }
        }
        .accessibilityLabel(config.label)
    }
}

// MARK: - Audio route picker

#if os(iOS)
/// Custom-styled audio-route button. Renders our CT 56pt circular control with
/// a route-aware SF Symbol, and overlays a transparent `AVRoutePickerView` that
/// captures taps and presents the system AirPlay / Bluetooth / Speaker picker.
/// The icon updates automatically on `AVAudioSession.routeChangeNotification`.
struct AudioRoutePickerButton: View {
    @State private var routeSymbol: String = "speaker.wave.2.fill"

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Image(systemName: routeSymbol)
                    .font(.system(size: CTLayout.callIconSize, weight: .medium))
                    .foregroundStyle(Color.CT.textDim)
                    .frame(width: 56, height: 56)
                    .background(Color.CT.bgMsg)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.CT.textDim.opacity(0.4), lineWidth: 1))

                // Apple's route picker sits on top with transparent tints so
                // its hit area maps onto our visible icon. Tap shows the
                // system route-selection sheet (AirPods, Bluetooth, Speaker…).
                AVRoutePickerViewRepresentable()
                    .frame(width: 56, height: 56)
                    .opacity(0.02) // tiny non-zero opacity keeps hit-testing on
            }

            Text(NSLocalizedString("call_audio_route", comment: ""))
                .font(CTFont.regular(10))
                .foregroundStyle(Color.CT.textDim)
        }
        .onAppear { updateSymbol() }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
            updateSymbol()
        }
        .accessibilityLabel(NSLocalizedString("call_audio_route", comment: ""))
    }

    private func updateSymbol() {
        let port = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType
        switch port {
        case .builtInSpeaker:
            routeSymbol = "speaker.wave.3.fill"
        case .builtInReceiver:
            routeSymbol = "speaker.fill"
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
            routeSymbol = "airpodspro"
        case .airPlay:
            routeSymbol = "airplayaudio"
        case .headphones, .headsetMic:
            routeSymbol = "headphones"
        default:
            routeSymbol = "speaker.wave.2.fill"
        }
    }
}

private struct AVRoutePickerViewRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        // Render system glyph transparent — our SwiftUI Image underneath is the visible icon.
        v.activeTintColor = .clear
        v.tintColor = .clear
        v.prioritizesVideoDevices = false
        v.backgroundColor = .clear
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif

#Preview {
    let session = CallManager.CallSession(
        id: UUID().uuidString,
        uuid: UUID(),
        peerUserId: "user_preview",
        peerName: "田中 あかり",
        direction: .outgoing
    )
    InCallView(session: session, isConnecting: false)
}
