//
//  TransportDiagnosticsView.swift
//  Construct Messenger
//
//  Debug-only screen showing live TransportRouter FSM state and recent transitions.
//  This is the answer to "why is the connection broken right now?" — every transport
//  decision flows through one place, and this screen reads that place directly.
//

#if DEBUG

import SwiftUI
import Combine

struct TransportDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var mirror = TransportRouterMirror.shared
    @State private var now = Date()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            CTNavBar(
                title: "TRANSPORT DIAGNOSTICS",
                showBack: true,
                backAction: { dismiss() }
            )
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    stateSection
                    routingSection
                    actionsSection
                    transitionsSection
                }
                .padding(.vertical, 12)
            }
        }
        .ctBackground()
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .onReceive(timer) { now = $0 }
    }

    // MARK: - Sections

    private var stateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            CTSettingsSectionHeader(title: "CURRENT STATE", color: .orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(stateHeadline)
                    .font(CTFont.bold(18))
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                ForEach(stateDetailLines, id: \.self) { line in
                    Text(line)
                        .font(CTFont.regular(12))
                        .foregroundStyle(Color.CT.textDim)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private var routingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            CTSettingsSectionHeader(title: "ROUTING", color: .orange)
            VStack(alignment: .leading, spacing: 4) {
                row("target", value: routingTarget)
                row("veil port", value: veilPortLabel)
                row("active relay", value: activeRelayLabel)
                row("prefers VEIL", value: mirror.state.prefersVEIL ? "yes" : "no")
            }
            .padding(.horizontal, 20)
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            CTSettingsSectionHeader(title: "ACTIONS", color: .orange)
            HStack(spacing: 12) {
                Button {
                    Task { await TransportRouter.shared.send(.manualReset) }
                } label: {
                    Text("[ MANUAL RESET ]")
                        .font(CTFont.regular(12))
                        .foregroundStyle(.orange)
                }
                Button {
                    mirror.clearHistory()
                } label: {
                    Text("[ CLEAR LOG ]")
                        .font(CTFont.regular(12))
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
        }
    }

    private var transitionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            CTSettingsSectionHeader(
                title: "TRANSITIONS (\(mirror.recentTransitions.count))",
                color: .orange
            )
            if mirror.recentTransitions.isEmpty {
                Text("(no transitions yet)")
                    .font(CTFont.regular(12))
                    .foregroundStyle(Color.CT.textDim)
                    .padding(.horizontal, 20)
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(mirror.recentTransitions.reversed().enumerated()), id: \.offset) { _, entry in
                        transitionRow(entry)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private func transitionRow(_ entry: TransitionLogEntry) -> some View {
        let arrow = entry.from == entry.to ? "•" : "→"
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(formatTime(entry.at))
                    .font(CTFont.regular(11))
                    .foregroundStyle(Color.CT.textDim)
                Text(entry.from.shortLabel)
                    .font(CTFont.regular(11))
                    .foregroundStyle(Color.CT.text)
                Text(arrow)
                    .font(CTFont.regular(11))
                    .foregroundStyle(.orange)
                Text(entry.to.shortLabel)
                    .font(CTFont.bold(11))
                    .foregroundStyle(entry.from == entry.to ? Color.CT.textDim : .orange)
            }
            Text("event: \(entry.event)")
                .font(CTFont.regular(10))
                .foregroundStyle(Color.CT.textDim)
            if !entry.effects.isEmpty {
                Text("effects: [\(entry.effects.joined(separator: ", "))]")
                    .font(CTFont.regular(10))
                    .foregroundStyle(Color.CT.textDim)
            }
            Rectangle()
                .fill(Color.CT.noise)
                .frame(height: 1)
                .padding(.top, 2)
        }
        .textSelection(.enabled)
    }

    // MARK: - Helpers

    private func row(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(CTFont.regular(12))
                .foregroundStyle(Color.CT.textDim)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(CTFont.regular(12))
                .foregroundStyle(Color.CT.text)
                .textSelection(.enabled)
        }
    }

    private var stateHeadline: String { mirror.state.shortLabel }

    private var stateDetailLines: [String] {
        switch mirror.state {
        case .offline:
            return ["network unreachable"]
        case .direct(let f):
            return ["consecutive direct failures: \(f)"]
        case .veilProbing:
            return ["probing"]
        case .veilActive(let r, let p, let since):
            let s = Int(now.timeIntervalSince(since))
            return ["relay: \(r)", "local port: \(p)", "active for: \(s)s"]
        case .veilCooldown(let until):
            let s = max(0, Int(until.timeIntervalSinceNow))
            return ["cooldown ends in: \(s)s"]
        }
    }

    private var routingTarget: String {
        if let port = mirror.state.veilPort {
            return "veil:\(port)"
        }
        return "direct"
    }

    private var veilPortLabel: String {
        mirror.state.veilPort.map { "\($0)" } ?? "—"
    }

    private var activeRelayLabel: String {
        mirror.state.currentRelay ?? "—"
    }

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: date)
    }
}

#endif
