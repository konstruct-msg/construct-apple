//
//  DesktopStudioCheckView.swift
//  Construct Desktop
//
//  The check before a call (`StudioCheckModel`): the DAW to take from, its sound on a meter, its
//  windows as the other side will see them, the talkback microphone and key, and what is wrong
//  with any of them, each with where to fix it. Runs while the window is open and no call is live.
//

import SwiftUI

struct DesktopStudioCheckView: View {
    @State private var check = StudioCheckModel.shared
    private let call = DesktopCallModel.shared

    private var inCall: Bool { call.phase?.isLive == true }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CTLayout.sectionGap) {
                Text(NSLocalizedString("studio_check_subtitle", comment: ""))
                    .font(CTFont.caption)
                    .foregroundStyle(Color.CT.textDim)

                if inCall {
                    Text(NSLocalizedString("studio_check_in_call", comment: ""))
                        .font(CTFont.body)
                        .foregroundStyle(Color.CT.text)
                } else {
                    sourceSection
                    programSection
                    if call.studioSendsScreen { screenSection }
                    talkbackSection
                    findingsSection
                    Button(NSLocalizedString("studio_check_again", comment: ""), action: restart)
                        .controlSize(.large)
                }
            }
            .padding(CTSpace.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .ctBackground()
        .onAppear {
            call.refreshStudioSources()
            call.setStudioCheckOpen(true)
            if !inCall { restart() }
        }
        .onDisappear {
            check.stop()
            call.setStudioCheckOpen(false)
        }
        .onChange(of: inCall) { _, live in
            if live { check.stop() } else { restart() }
        }
    }

    private func restart() {
        check.start(source: call.studioSource, sendsScreen: call.studioSendsScreen)
    }

    // MARK: - Sections

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: CTSpace.s) {
            Picker(NSLocalizedString("studio_source", comment: ""), selection: Binding(
                get: { call.studioSource },
                set: { if let source = $0 { call.setStudioSource(source); restart() } }
            )) {
                if call.studioSource == nil {
                    Text(NSLocalizedString("studio_source_none", comment: "")).tag(StudioSource?.none)
                }
                ForEach(call.studioSources, id: \.self) { source in
                    Text(source.name).tag(Optional(source))
                }
            }
            .pickerStyle(.menu)
            Toggle(NSLocalizedString("studio_send_screen", comment: ""), isOn: Binding(
                get: { call.studioSendsScreen },
                set: { call.setStudioSendsScreen($0); restart() }
            ))
            .toggleStyle(.switch)
        }
    }

    private var programSection: some View {
        section("studio_check_program") {
            VStack(alignment: .leading, spacing: CTSpace.xs) {
                meterRow("studio_check_left", level: check.left)
                meterRow("studio_check_right", level: check.right)
            }
            if case .running(let meter) = check.capture, meter.clipped {
                HStack(spacing: CTSpace.s) {
                    Label(NSLocalizedString("studio_check_clip", comment: ""), systemImage: "exclamationmark.triangle.fill")
                        .font(CTFont.caption)
                        .foregroundStyle(Color.CT.danger)
                    Button(NSLocalizedString("studio_check_clip_reset", comment: ""), action: check.resetClip)
                        .controlSize(.small)
                }
            }
        }
    }

    private var screenSection: some View {
        section("studio_check_screen") {
            if let preview = check.preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(CTShape.card())
                    .overlay(CTShape.card().stroke(Color.CT.noise))
            } else {
                Text(NSLocalizedString(check.screen == .notStarted || check.screen == .showing
                                       ? "studio_check_screen_waiting" : "studio_check_screen_none", comment: ""))
                    .font(CTFont.caption)
                    .foregroundStyle(Color.CT.textDim)
                    .frame(maxWidth: .infinity, minHeight: CTLayout.hitTarget * 3)
                    .background(Color.CT.noise.opacity(0.4), in: CTShape.card())
            }
        }
    }

    private var talkbackSection: some View {
        section("studio_talkback") {
            HStack(spacing: CTSpace.s) {
                Image(systemName: "mic")
                    .font(CTFont.ui(CTIcon.caption))
                    .foregroundStyle(Color.CT.textDim)
                bar(check.microphone)
            }
            Picker(NSLocalizedString("studio_talkback", comment: ""), selection: Binding(
                get: { call.talkback.mode },
                set: { call.setTalkbackMode($0) }
            )) {
                Text(NSLocalizedString("studio_talkback_hold", comment: "")).tag(StudioTalkbackMode.holdToTalk)
                Text(NSLocalizedString("studio_talkback_always", comment: "")).tag(StudioTalkbackMode.alwaysOn)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if call.talkback.mode == .holdToTalk {
                let held = call.talkback.held
                Label(String(format: NSLocalizedString(held ? "studio_check_key_held" : "studio_check_key_up", comment: ""),
                             StudioTalkKey.label),
                      systemImage: held ? "keyboard.fill" : "keyboard")
                    .font(CTFont.caption)
                    .foregroundStyle(held ? Color.CT.accent : Color.CT.textDim)
            }
        }
    }

    @ViewBuilder
    private var findingsSection: some View {
        let findings = check.findings(source: call.studioSource, sendsScreen: call.studioSendsScreen)
        if findings.isEmpty {
            if case .running = check.capture {
                Label(NSLocalizedString("studio_check_all_good", comment: ""), systemImage: "checkmark.circle.fill")
                    .font(CTFont.body)
                    .foregroundStyle(Color.CT.online)
            }
        } else {
            VStack(alignment: .leading, spacing: CTSpace.m) {
                ForEach(Array(findings.enumerated()), id: \.offset) { _, finding in
                    findingRow(finding)
                }
            }
        }
    }

    private func findingRow(_ finding: StudioCheckFinding) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: CTSpace.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.CT.warning)
            VStack(alignment: .leading, spacing: CTSpace.xs) {
                Text(text(for: finding))
                    .font(CTFont.body)
                    .foregroundStyle(Color.CT.text)
                    .fixedSize(horizontal: false, vertical: true)
                switch finding {
                case .silent, .screenPermissionMissing:
                    Button(NSLocalizedString("studio_open_screen_settings", comment: ""), action: call.openScreenRecordingSettings)
                        .controlSize(.small)
                case .microphonePermissionMissing:
                    Button(NSLocalizedString("studio_allow_microphone", comment: ""), action: check.requestMicrophone)
                        .controlSize(.small)
                default:
                    EmptyView()
                }
            }
        }
    }

    private func text(for finding: StudioCheckFinding) -> String {
        let name = call.studioSource?.name ?? NSLocalizedString("studio_source_generic", comment: "")
        switch finding {
        case .noSource: return NSLocalizedString("studio_finding_no_source", comment: "")
        case .sourceNeverPlayed: return String(format: NSLocalizedString("studio_finding_never_played", comment: ""), name)
        case .sampleRate(let rate): return String(format: NSLocalizedString("studio_finding_sample_rate", comment: ""), rate)
        case .captureFailed: return String(format: NSLocalizedString("studio_finding_capture_failed", comment: ""), name)
        case .silent: return String(format: NSLocalizedString("studio_finding_silent", comment: ""), name)
        case .clipping: return NSLocalizedString("studio_finding_clipping", comment: "")
        case .screenPermissionMissing: return NSLocalizedString("studio_finding_screen_permission", comment: "")
        case .screenNoWindow: return String(format: NSLocalizedString("studio_finding_screen_no_window", comment: ""), name)
        case .microphonePermissionMissing: return NSLocalizedString("studio_finding_mic_permission", comment: "")
        }
    }

    // MARK: - Pieces

    private func section(_ titleKey: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: CTSpace.s) {
            Text(NSLocalizedString(titleKey, comment: ""))
                .font(CTFont.headline)
                .foregroundStyle(Color.CT.text)
            content()
        }
    }

    private func meterRow(_ key: String, level: Float) -> some View {
        HStack(spacing: CTSpace.s) {
            Text(NSLocalizedString(key, comment: ""))
                .font(CTFont.caption)
                .foregroundStyle(Color.CT.textDim)
                .frame(width: CTSpace.l, alignment: .leading)
            bar(StudioMeter.fill(level), loud: level > -1)
            Text(level <= StudioMeter.floorDB ? "−∞" : String(format: "%.0f", level))
                .font(CTFont.mono(CTIcon.caption))
                .foregroundStyle(Color.CT.textDim)
                .frame(width: CTSpace.xxl, alignment: .trailing)
                .accessibilityLabel(String(format: "%.0f dBFS", level))
        }
    }

    private func bar(_ fill: Double, loud: Bool = false) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                CTShape.badge().fill(Color.CT.noise)
                CTShape.badge()
                    .fill(loud ? Color.CT.danger : Color.CT.accent)
                    .frame(width: geometry.size.width * min(1, max(0, fill)))
            }
        }
        .frame(height: CTSpace.s)
        .accessibilityValue(String(format: "%.0f%%", fill * 100))
    }
}
