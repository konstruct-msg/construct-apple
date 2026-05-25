//
//  NetworkSettingsView.swift
//  Construct Messenger
//

import SwiftUI

struct NetworkSettingsView: View {
    var showNavBar: Bool = true

    init(showNavBar: Bool = true) {
        self.showNavBar = showNavBar
    }

    @Environment(\.dismiss) private var dismiss
    @State private var connectionManager = ConnectionStatusManager.shared
    @State private var streamManager = MessageStreamManager.shared

    // Custom server (Debug only)
    @State private var customHost = GRPCChannelManager.shared.currentHost
    @State private var customPort = "\(GRPCChannelManager.shared.currentPort)"
    @State private var showingAppliedAlert = false

    @ObservedObject private var iceManager = IceProxyManager.shared

    var body: some View {
        VStack(spacing: 0) {
            if showNavBar {
                CTNavBar(
                    title: NSLocalizedString("network", comment: ""),
                    showBack: true,
                    backAction: { dismiss() }
                )
            }
            ScrollView {
            LazyVStack(spacing: NetworkSettingsLayout.compactSectionSpacing) {

                // MARK: - Connection Status
                CTSettingsSectionHeader(title: NSLocalizedString("status", comment: "").uppercased())
                let path = iceManager.currentTrafficPath
                CTSectionGroup {
                    HStack(spacing: NetworkSettingsLayout.statusRowSpacing) {
                        Text(connectionStatusASCII)
                            .font(CTFont.regular(13))
                            .foregroundColor(statusColor)
                        VStack(alignment: .leading, spacing: NetworkSettingsLayout.statusDetailSpacing) {
                            Text(connectionManager.connectionStatus.displayText)
                                .font(CTFont.regular(13))
                                .foregroundStyle(Color.CT.text)
                            if connectionManager.connectionStatus != .connected,
                               let phase = connectionManager.connectingPhase {
                                Text(phase)
                                    .font(CTFont.regular(11))
                                    .foregroundStyle(.orange)
                                    .textSelection(.enabled)
                                    .transition(.opacity)
                            }
                            Text(path.displayDetail)
                                .font(CTFont.regular(11))
                                .foregroundStyle(Color.CT.textDim)
                                .textSelection(.enabled)
                        }
                        
                        Spacer()
                        
                        let displayTransport = streamManager.activeTransport.isEmpty
                            ? streamManager.lastActiveTransport
                            : streamManager.activeTransport
                        let isLive = !streamManager.activeTransport.isEmpty
                        if !displayTransport.isEmpty {
                            let isQUIC = displayTransport == "H3"
                            Text(isQUIC ? NetworkSettingsLabels.quic : NetworkSettingsLabels.h2)
                                .font(CTFont.regular(13))
                                .foregroundColor(isLive
                                    ? (isQUIC ? Color.CT.accent : Color.CT.accentDim)
                                    : Color.CT.textDim)
                                .padding(.horizontal, NetworkSettingsLayout.transportBadgeHorizontalPadding)
                                .padding(.vertical, NetworkSettingsLayout.transportBadgeVerticalPadding)
                                .overlay(RoundedRectangle(cornerRadius: NetworkSettingsLayout.transportBadgeCornerRadius).stroke(
                                    (isLive ? Color.CT.accent : Color.CT.textDim).opacity(NetworkSettingsLayout.transportBadgeStrokeOpacity),
                                    lineWidth: NetworkSettingsLayout.transportBadgeStrokeWidth))
                        }
                    }
                    .padding(.horizontal, NetworkSettingsLayout.rowHorizontalPadding)
                    .padding(.vertical, NetworkSettingsLayout.rowVerticalPadding)

                    if let heartbeat = streamManager.lastHeartbeatDate {
                        CTSep(style: .thin)
                        HStack {
                            Text(LocalizedStringKey("last_heartbeat"))
                                .font(CTFont.regular(13))
                                .foregroundStyle(Color.CT.textDim)
                            Spacer()
                            Text(heartbeat, style: .relative)
                                .font(CTFont.regular(13))
                                .foregroundStyle(Color.CT.textDim)
                                .monospacedDigit()
                        }
                        .padding(.horizontal, NetworkSettingsLayout.rowHorizontalPadding)
                        .padding(.vertical, NetworkSettingsLayout.compactRowVerticalPadding)
                    }

                    if let error = connectionManager.lastError {
                        CTSep(style: .thin)
                        Text(error)
                            .font(CTFont.regular(NetworkSettingsLayout.errorMonospacedFontSize))
                            .foregroundStyle(Color.CT.danger)
                            .textSelection(.enabled)
                            .padding(.horizontal, NetworkSettingsLayout.rowHorizontalPadding)
                            .padding(.vertical, NetworkSettingsLayout.compactRowVerticalPadding)
                    }
                }

                // MARK: - Traffic Protection (ICE)
                CTSettingsSectionHeader(title: NSLocalizedString("traffic_protection", comment: "").uppercased())
                CTSectionGroup {
                    // Tri-state mode selector
                    HStack {
                        Text(LocalizedStringKey("ice_title"))
                            .font(CTFont.regular(13))
                            .foregroundColor(
                                iceManager.hasCert
                                ? Color.CT.textDim
                                : Color.CT.textDim.opacity(NetworkSettingsLayout.statusDisabledOpacity)
                            )
                        Spacer()
                        CTModeSelector(
                            selection: Binding(
                                get: { iceManager.mode },
                                set: { newMode in
                                    let oldMode = iceManager.mode
                                    iceManager.mode = newMode
                                    switch newMode {
                                    case .off:
                                        iceManager.stop()
                                    case .auto:
                                        // Switching to auto: stop proxy, let DPI detection handle it.
                                        if oldMode == .on { iceManager.stop() }
                                    case .on:
                                        Task { await iceManager.startIfEnabled() }
                                    }
                                }
                            ),
                            options: IceMode.allCases,
                            labels: [
                                .off:  NSLocalizedString("ice_mode_off", comment: ""),
                                .auto: NSLocalizedString("ice_mode_auto", comment: ""),
                                .on:   NSLocalizedString("ice_mode_on", comment: "")
                            ]
                        )
                        .disabled(!iceManager.hasCert)
                    }
                    .padding(.horizontal, NetworkSettingsLayout.rowHorizontalPadding)
                    .padding(.vertical, NetworkSettingsLayout.rowVerticalPadding)

                    if (iceManager.mode != .off || iceManager.isRunning) && iceManager.hasCert {
                        if iceManager.isOnCooldown {
                            CTSep(style: .thin)
                            HStack {
                                Text(LocalizedStringKey("ice_retry"))
                                    .font(CTFont.regular(13))
                                    .foregroundColor(Color.CT.textDim)
                                Spacer()
                                Text(CTSymbol.refresh)
                                    .font(CTFont.regular(13))
                                    .foregroundColor(Color.CT.textDim)
                            }
                            .padding(.horizontal, NetworkSettingsLayout.rowHorizontalPadding)
                            .padding(.vertical, NetworkSettingsLayout.rowVerticalPadding)
                        } else if iceManager.isRunning, let relay = iceManager.activeRelay {
                            CTSep(style: .thin)
                            HStack {
                                Text(pathASCII(iceManager.currentTrafficPath))
                                    .font(CTFont.regular(13))
                                    .foregroundColor(pathColor(iceManager.currentTrafficPath))
                                Text(relay.address)
                                    .font(CTFont.regular(NetworkSettingsLayout.relayAddressFontSize))
                                    .foregroundColor(Color.CT.textDim)
                                    .textSelection(.enabled)
                                Spacer()
                                let quality = iceManager.qualityForRelay(relay.address)
                                relayBadge(label: quality.badge, color: quality.badgeColor)
                                if relay.tlsServerName != nil {
                                    relayBadge(label: NetworkSettingsLabels.tls, color: Color.CT.accentDim)
                                    relayBadge(label: NetworkSettingsLabels.obfs4, color: Color.CT.accentDim)
                                } else {
                                    relayBadge(label: NetworkSettingsLabels.obfs4, color: Color.CT.accentDim)
                                }
                            }
                            .padding(.horizontal, NetworkSettingsLayout.rowHorizontalPadding)
                            .padding(.vertical, NetworkSettingsLayout.relayRowVerticalPadding)

                        } else if iceManager.mode != .off && !iceManager.isRunning {
                            CTSep(style: .thin)
                            Text(iceManager.lastError ?? NSLocalizedString("ice_unavailable", comment: ""))
                                .font(CTFont.regular(11))
                                .foregroundStyle(Color.CT.textDim)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, NetworkSettingsLayout.rowHorizontalPadding)
                                .padding(.vertical, NetworkSettingsLayout.compactRowVerticalPadding)
                        }
                    }
                }

                // Footer — mode-specific
                if !iceManager.hasCert {
                    Text(LocalizedStringKey("ice_unavailable"))
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, NetworkSettingsLayout.rowHorizontalPadding)
                        .padding(.bottom, NetworkSettingsLayout.footerVerticalPadding)
                } else {
                    Text(LocalizedStringKey(iceFooterKey))
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, NetworkSettingsLayout.rowHorizontalPadding)
                        .padding(.vertical, NetworkSettingsLayout.footerVerticalPadding)
                }
            }
            .padding(.vertical, NetworkSettingsLayout.sectionVerticalPadding)
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            }
        .alert("server_applied_title", isPresented: $showingAppliedAlert) {
            Button("ok") { }
        } message: {
            Text("server_applied_message")
        }
        }
        .background(Color.CT.bg.ignoresSafeArea())
    }

    // MARK: - Actions

    private func applyCustomServer() {
        let host = customHost.trimmingCharacters(in: .whitespaces)
        let port = Int(customPort.trimmingCharacters(in: .whitespaces)) ?? 443
        GRPCChannelManager.shared.setCustomServer(host: host, port: port)
        showingAppliedAlert = true
    }

    @ViewBuilder
    private func relayBadge(label: String, color: Color) -> some View {
        Text(label)
            .font(CTFont.regular(NetworkSettingsLayout.relayBadgeFontSize))
            .foregroundColor(color)
            .padding(.horizontal, NetworkSettingsLayout.transportBadgeHorizontalPadding)
            .padding(.vertical, NetworkSettingsLayout.transportBadgeVerticalPadding)
            .overlay(
                Rectangle().stroke(
                    color.opacity(NetworkSettingsLayout.transportBadgeStrokeOpacity),
                    lineWidth: NetworkSettingsLayout.transportBadgeStrokeWidth
                )
            )
    }

    // MARK: - Helpers

    private var iceFooterKey: String {
        switch iceManager.mode {
        case .off:  return "ice_footer_off"
        case .auto: return "ice_footer_auto"
        case .on:   return "ice_footer_on"
        }
    }

    private var statusColor: Color {
        switch connectionManager.connectionStatus {
        case .connected:    return Color.CT.accent
        case .disconnected: return Color.CT.danger
        case .connecting:   return .orange
        case .unknown:      return Color.CT.textDim
        }
    }

    private var connectionStatusASCII: String {
        switch connectionManager.connectionStatus {
        case .connected:    return "[ok]"
        case .disconnected: return "[err]"
        case .connecting:   return "[~]"
        case .unknown:      return "[?]"
        }
    }

    private func pathASCII(_ path: TrafficPath) -> String {
        switch path {
        case .direct:          return "[→]"
        case .icePrimary:      return "[t]"
        case .iceRelay:        return "[t]"
        case .iceWebTunnel:    return "[ws]"
        case .iceCooldown:     return "[!]"
        case .iceConnecting:   return "[~]"
        }
    }

    private func pathColor(_ path: TrafficPath) -> Color {
        switch path {
        case .direct:          return Color.CT.accentDim
        case .icePrimary:      return Color.CT.accent
        case .iceRelay:        return Color.CT.accentDim
        case .iceWebTunnel:    return Color.CT.accent
        case .iceCooldown:     return .orange
        case .iceConnecting:   return .orange
        }
    }
}

#Preview {
    NavigationStack {
        NetworkSettingsView()
    }
        .preferredColorScheme(.dark)
}
