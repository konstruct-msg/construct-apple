//
//  DesktopCallViews.swift
//  Construct Desktop
//
//  The macOS call surfaces (design: claude.ai/artifact/NjvFrSAuKZxc43tqxRJHdj):
//  - the incoming panel, over the main window;
//  - the call bar, at the top of the chat column while a call holds the microphone;
//  - the call window, its own small window, which shows every phase including how a call ended;
//  - the microphone and output picker, a popover from either.
//  All of them read `DesktopCallModel`, so the bar and the window never disagree.
//

import AVFoundation
import SwiftUI

// MARK: - Shared pieces

/// A phase as words. `seconds` ticks while connected.
@MainActor
private func callStatus(_ phase: CallPhase, seconds: Int?) -> String {
    switch phase {
    case .incoming: return NSLocalizedString("call_incoming_audio", comment: "")
    case .calling: return NSLocalizedString("call_status_calling", comment: "")
    case .ringing: return NSLocalizedString("call_status_ringing", comment: "")
    case .connecting: return NSLocalizedString("call_connecting", comment: "")
    case .live: return seconds.map(formatCallDuration) ?? NSLocalizedString("call_status_connected", comment: "")
    case .reconnecting: return NSLocalizedString("call_reconnecting_title", comment: "")
    case .over(let outcome):
        switch outcome {
        case .ended(let s?): return String(format: NSLocalizedString("call_ended_after", comment: ""), formatCallDuration(s))
        case .ended(nil): return NSLocalizedString("call_ended", comment: "")
        case .declined: return NSLocalizedString("call_declined", comment: "")
        case .busy: return NSLocalizedString("call_busy", comment: "")
        case .noAnswer: return NSLocalizedString("call_no_answer", comment: "")
        case .failed: return NSLocalizedString("call_not_connected", comment: "")
        }
    }
}

/// The line under the status that says what happened and what to do, where there is one.
private func callDetail(_ phase: CallPhase) -> String? {
    switch phase {
    case .reconnecting: return NSLocalizedString("call_detail_reconnecting", comment: "")
    case .over(.declined): return NSLocalizedString("call_detail_declined", comment: "")
    case .over(.busy): return NSLocalizedString("call_detail_busy", comment: "")
    case .over(.noAnswer): return NSLocalizedString("call_detail_no_answer", comment: "")
    case .over(.failed): return NSLocalizedString("call_detail_failed", comment: "")
    default: return nil
    }
}

private func formatCallDuration(_ s: Int) -> String {
    s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
}

/// Re-renders its content every second while the call is connected, so durations tick.
private struct CallTicker<Content: View>: View {
    let model: DesktopCallModel
    @ViewBuilder let content: (Int?) -> Content

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            content(model.connectedSeconds)
        }
    }
}

/// Mute: the platform's control language — a symbol whose state is the symbol, filled when on.
private struct CallMuteButton: View {
    let model: DesktopCallModel
    let size: CGFloat

    var body: some View {
        Button(action: model.toggleMute) {
            Image(systemName: model.muted ? "mic.slash.fill" : "mic.fill")
                .font(CTFont.ui(size * 0.4, weight: .medium))
                .foregroundStyle(model.muted ? Color.CT.bg : Color.CT.text)
                .frame(width: size, height: size)
                .background(model.muted ? Color.CT.text : Color.CT.noise, in: Circle())
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString(model.muted ? "call_unmute" : "call_mute", comment: "") + " (⌘⇧M)")
        .accessibilityLabel(NSLocalizedString(model.muted ? "call_unmute" : "call_mute", comment: ""))
    }
}

private struct CallDevicesButton: View {
    let size: CGFloat
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "headphones")
                .font(CTFont.ui(size * 0.4, weight: .medium))
                .foregroundStyle(Color.CT.text)
                .frame(width: size, height: size)
                .background(Color.CT.noise, in: Circle())
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("call_audio_devices", comment: ""))
        .accessibilityLabel(NSLocalizedString("call_audio_devices", comment: ""))
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            DesktopAudioDevicesView()
        }
    }
}

/// Studio: on and off like mute — the symbol filled with the accent while Studio is on.
private struct CallStudioButton: View {
    let model: DesktopCallModel
    let size: CGFloat

    var body: some View {
        let key = model.studioOn ? "call_studio_stop" : "call_studio_start"
        Button(action: model.toggleStudio) {
            Image(systemName: "waveform")
                .font(CTFont.ui(size * 0.4, weight: .medium))
                .foregroundStyle(model.studioOn ? Color.CT.onFill : Color.CT.text)
                .frame(width: size, height: size)
                .background(model.studioOn ? Color.CT.accent : Color.CT.noise, in: Circle())
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString(key, comment: ""))
        .accessibilityLabel(NSLocalizedString(key, comment: ""))
    }
}

private struct CallEndButton: View {
    let model: DesktopCallModel
    let size: CGFloat

    var body: some View {
        Button(action: model.end) {
            Image(systemName: "phone.down.fill")
                .font(CTFont.ui(size * 0.4, weight: .medium))
                .foregroundStyle(Color.CT.onFill)
                .frame(width: size, height: size)
                .background(Color.CT.danger, in: Circle())
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("call_end", comment: "") + " (⌘⇧E)")
        .accessibilityLabel(NSLocalizedString("call_end", comment: ""))
    }
}

// MARK: - Incoming panel

/// Shown over the main window while a call rings here. Return answers, Escape declines.
struct DesktopIncomingCallPanel: View {
    let session: CallSession

    var body: some View {
        VStack(alignment: .leading, spacing: CTSpace.l) {
            HStack(spacing: CTSpace.m) {
                MainAvatarView(userId: session.peerUserId, displayName: session.peerName, size: CTAvatarSize.header)
                VStack(alignment: .leading, spacing: CTSpace.xs) {
                    Text(session.peerName)
                        .font(CTFont.headline)
                        .foregroundStyle(Color.CT.text)
                        .lineLimit(1)
                    Text(NSLocalizedString("call_incoming_audio", comment: ""))
                        .font(CTFont.secondary)
                        .foregroundStyle(Color.CT.textDim)
                }
            }
            HStack(spacing: CTLayout.chromeGap) {
                Button {
                    CallManager.shared.declineIncomingCall()
                } label: {
                    Label(NSLocalizedString("call_decline", comment: ""), systemImage: "phone.down.fill")
                        .frame(maxWidth: .infinity, minHeight: CTLayout.hitTarget)
                }
                .buttonStyle(.plain)
                .font(CTFont.bodyEmphasis)
                .foregroundStyle(Color.CT.onFill)
                .background(Color.CT.danger, in: CTShape.control())
                .keyboardShortcut(.cancelAction)

                Button {
                    CallManager.shared.answerIncomingCall(withCamera: false)
                } label: {
                    Label(NSLocalizedString("call_answer", comment: ""), systemImage: "phone.fill")
                        .frame(maxWidth: .infinity, minHeight: CTLayout.hitTarget)
                }
                .buttonStyle(.plain)
                .font(CTFont.bodyEmphasis)
                .foregroundStyle(Color.CT.onFill)
                .background(Color.CT.accent, in: CTShape.control())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(CTSpace.xl)
        .frame(width: 400)
        .background(Color.CT.bgMsg, in: CTShape.card())
        .overlay(CTShape.card().strokeBorder(Color.CT.noise, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
        .padding(CTSpace.l)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(format: NSLocalizedString("call_incoming_from", comment: ""), session.peerName))
    }
}

// MARK: - Call bar

/// At the top of the chat column while the call holds the microphone, whichever chat is open.
struct DesktopCallBar: View {
    let model: DesktopCallModel
    let onOpenWindow: () -> Void

    var body: some View {
        if let session = model.session, let phase = model.phase, phase.isLive {
            HStack(spacing: CTSpace.m) {
                MainAvatarView(userId: session.peerUserId, displayName: session.peerName, size: CTAvatarSize.compact)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: NSLocalizedString("call_with", comment: ""), session.peerName))
                        .font(CTFont.bodyEmphasis)
                        .foregroundStyle(Color.CT.text)
                        .lineLimit(1)
                    CallTicker(model: model) { seconds in
                        Text(barStatus(phase, seconds: seconds))
                            .font(CTFont.secondary)
                            .foregroundStyle(phase == .reconnecting ? Color.CT.warning : Color.CT.textDim)
                    }
                }
                Spacer(minLength: CTSpace.m)
                CallMuteButton(model: model, size: CTLayout.controlHeight - 6)
                CallDevicesButton(size: CTLayout.controlHeight - 6)
                Button(action: onOpenWindow) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(CTFont.ui(14, weight: .medium))
                        .foregroundStyle(Color.CT.text)
                        .frame(width: CTLayout.controlHeight - 6, height: CTLayout.controlHeight - 6)
                        .background(Color.CT.noise, in: Circle())
                }
                .buttonStyle(.plain)
                .help(NSLocalizedString("call_open_window", comment: ""))
                .accessibilityLabel(NSLocalizedString("call_open_window", comment: ""))
                CallEndButton(model: model, size: CTLayout.controlHeight - 6)
            }
            .padding(.horizontal, CTSpace.l)
            .padding(.vertical, CTSpace.s)
            .background(Color.CT.accent.opacity(0.12))
            .overlay(alignment: .bottom) { Rectangle().fill(Color.CT.accent.opacity(0.25)).frame(height: 1) }
        }
    }

    private func barStatus(_ phase: CallPhase, seconds: Int?) -> String {
        let status = callStatus(phase, seconds: seconds)
        return model.muted ? status + " · " + NSLocalizedString("call_mic_off", comment: "") : status
    }
}

// MARK: - Call window

/// The call's own window. Opens when a call starts or is answered; keeps a call that ended with
/// something to act on until it is closed.
struct DesktopCallWindowView: View {
    let model: DesktopCallModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            if let phase = model.phase, phase.isLive, model.micAccess == .denied {
                micDeniedBanner
            }
            Spacer(minLength: CTSpace.l)
            if let session = model.session, let phase = model.phase {
                peer(session, phase)
            }
            Spacer(minLength: CTSpace.l)
            controls
                .padding(.bottom, CTSpace.l)
            footer
        }
        .frame(minWidth: 360, idealWidth: 440, minHeight: 480, idealHeight: 600)
        .ctBackground()
        .navigationTitle(NSLocalizedString("call_window_title", comment: ""))
        .onChange(of: model.phase) { _, phase in
            if phase == nil { dismissWindow() }
        }
    }

    private func peer(_ session: CallSession, _ phase: CallPhase) -> some View {
        VStack(spacing: CTSpace.m) {
            MainAvatarView(userId: session.peerUserId, displayName: session.peerName, size: CTAvatarSize.hero)
                .padding(CTSpace.s)
                .overlay(Circle().strokeBorder(waiting(phase) ? Color.CT.accent.opacity(0.35) : .clear, lineWidth: 2))
            Text(session.peerName)
                .font(CTFont.title)
                .foregroundStyle(Color.CT.text)
                .lineLimit(1)
            CallTicker(model: model) { seconds in
                Text(windowStatus(phase, seconds: seconds))
                    .font(CTFont.body)
                    .foregroundStyle(statusColor(phase))
            }
            .accessibilityAddTraits(.updatesFrequently)
            if let detail = callDetail(phase) {
                Text(detail)
                    .font(CTFont.secondary)
                    .foregroundStyle(Color.CT.textDim)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
        .padding(.horizontal, CTSpace.xl)
    }

    @ViewBuilder
    private var controls: some View {
        switch model.phase {
        case .over?:
            HStack(spacing: CTLayout.chromeGap) {
                Button(NSLocalizedString("call_dismiss", comment: "")) { model.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(NSLocalizedString("call_call_back", comment: "")) { model.callBack() }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        case let phase? where phase.isLive:
            HStack(alignment: .top, spacing: CTSpace.l) {
                labelled(model.muted ? "call_mic_off" : "call_microphone") {
                    CallMuteButton(model: model, size: CTLayout.callControlSize)
                }
                labelled("call_sound") { CallDevicesButton(size: CTLayout.callControlSize) }
                if model.studioAvailable {
                    labelled("call_studio") { CallStudioButton(model: model, size: CTLayout.callControlSize) }
                }
                labelled("call_end") { CallEndButton(model: model, size: CTLayout.callControlSize) }
            }
        default:
            EmptyView()
        }
    }

    private func labelled(_ key: String, @ViewBuilder _ control: () -> some View) -> some View {
        VStack(spacing: CTSpace.s) {
            control()
            Text(NSLocalizedString(key, comment: ""))
                .font(CTFont.caption)
                .foregroundStyle(Color.CT.textDim)
        }
        .frame(width: 84)
    }

    private var micDeniedBanner: some View {
        VStack(alignment: .leading, spacing: CTSpace.s) {
            Text(NSLocalizedString("call_mic_denied", comment: ""))
                .font(CTFont.secondary)
                .foregroundStyle(Color.CT.text)
            Button(NSLocalizedString("call_open_settings", comment: "")) { model.openMicrophoneSettings() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(CTSpace.m)
        .background(Color.CT.warning.opacity(0.15), in: CTShape.card())
        .overlay(CTShape.card().strokeBorder(Color.CT.warning.opacity(0.4), lineWidth: 1))
        .padding([.horizontal, .top], CTSpace.l)
    }

    private var footer: some View {
        HStack(spacing: CTSpace.s) {
            Image(systemName: "lock.fill").font(CTFont.ui(CTIcon.caption - 2))
            Text(NSLocalizedString("call_encrypted_via_relay", comment: ""))
        }
        .font(CTFont.caption)
        .foregroundStyle(Color.CT.textDim)
        .frame(maxWidth: .infinity)
        .padding(.vertical, CTSpace.m)
        .overlay(alignment: .top) { Rectangle().fill(Color.CT.noise).frame(height: 1) }
    }

    private func windowStatus(_ phase: CallPhase, seconds: Int?) -> String {
        let status = callStatus(phase, seconds: seconds)
        return phase.isLive && model.muted ? status + " · " + NSLocalizedString("call_mic_off", comment: "") : status
    }

    private func waiting(_ phase: CallPhase) -> Bool {
        phase == .calling || phase == .ringing || phase == .connecting
    }

    private func statusColor(_ phase: CallPhase) -> Color {
        switch phase {
        case .reconnecting: Color.CT.warning
        case .over(.failed): Color.CT.danger
        case .over: Color.CT.textDim
        default: Color.CT.text
        }
    }
}

// MARK: - Microphone and output

/// The Mac's microphones and outputs, as WebRTC's audio device module lists them. "System
/// default" follows the system's choice when it changes.
struct DesktopAudioDevicesView: View {
    @State private var inputs: [WebRTCAudioDevices.Device] = []
    @State private var outputs: [WebRTCAudioDevices.Device] = []
    @State private var input: String?
    @State private var output: String?
    @State private var level: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: CTSpace.xs) {
            section("call_microphone", devices: inputs, selected: input) { id in
                WebRTCAudioDevices.selectedInput = id
                input = id
            }
            ProgressView(value: level)
                .progressViewStyle(.linear)
                .padding(.leading, CTSpace.xxl)
                .accessibilityLabel(NSLocalizedString("call_mic_level", comment: ""))
            Text(NSLocalizedString("call_mic_level_hint", comment: ""))
                .font(CTFont.caption)
                .foregroundStyle(Color.CT.textDim)
                .padding(.leading, CTSpace.xxl)
                .padding(.bottom, CTSpace.s)
            section("call_audio_output", devices: outputs, selected: output) { id in
                WebRTCAudioDevices.selectedOutput = id
                output = id
            }
        }
        .padding(CTSpace.m)
        .frame(width: 340)
        .onAppear(perform: reload)
        .task {
            while !Task.isCancelled {
                level = await CallManager.shared.microphoneLevel() ?? 0
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func reload() {
        inputs = WebRTCAudioDevices.inputs
        outputs = WebRTCAudioDevices.outputs
        input = WebRTCAudioDevices.selectedInput
        output = WebRTCAudioDevices.selectedOutput
    }

    private func section(_ titleKey: String, devices: [WebRTCAudioDevices.Device], selected: String?,
                         pick: @escaping (String?) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(NSLocalizedString(titleKey, comment: ""))
                .font(CTFont.caption)
                .foregroundStyle(Color.CT.textDim)
                .padding(.vertical, CTSpace.xs)
            row(NSLocalizedString("call_device_system", comment: ""), on: selected == nil) { pick(nil) }
            ForEach(devices) { device in
                row(device.name, on: selected == device.id) { pick(device.id) }
            }
        }
    }

    private func row(_ name: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: CTSpace.s) {
                Image(systemName: "checkmark")
                    .font(CTFont.ui(CTIcon.caption, weight: .semibold))
                    .foregroundStyle(Color.CT.accent)
                    .opacity(on ? 1 : 0)
                    .frame(width: CTSpace.xl)
                Text(name)
                    .font(CTFont.body)
                    .foregroundStyle(Color.CT.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
