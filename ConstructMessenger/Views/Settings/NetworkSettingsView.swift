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

    @ObservedObject private var veilManager = VeilProxyManager.shared

    // VEIL access provisioning (per-user ticket imported out-of-band).
    @State private var showingVeilScanner = false
    @State private var showingVeilPaste = false
    @State private var veilPasteText = ""
    @State private var veilImportMessage: String?
    @State private var veilImportIsError = false
    /// Bumped after an import to refresh the configured-status row.
    @State private var veilTicketRefresh = 0
//    #if DEBUG
    @State private var engineQuicOn = FeatureFlags.engineQuicExperimental
//    #endif
    #if DEBUG
    @State private var engineQuicObfOn = FeatureFlags.engineQuicObfuscated
    #endif

    private var veilConfiguredRelay: String? {
        _ = veilTicketRefresh
        let addr = VEILConfig.ruRelayAddress
        return VeilTicketStore.ticket(for: addr) != nil ? addr : nil
    }

    private var hasVeilAccessConfigured: Bool {
        veilConfiguredRelay != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if showNavBar {
                CTNavBar(
                    title: NSLocalizedString("network", comment: ""),
                    showBack: true,
                    backAction: { dismiss() }
                ) {
                    EmptyView()
                } trailing: {
                    EmptyView()
                }
            }
            ScrollView {
            LazyVStack(spacing: NetworkSettingsLayout.compactSectionSpacing) {

                // MARK: - Connection Status
                CTSettingsSectionHeader(title: NSLocalizedString("status", comment: "").uppercased())
                let path = veilManager.currentTrafficPath
                CTSectionGroup {
                    HStack(spacing: NetworkSettingsLayout.statusRowSpacing) {
                        Image(systemName: connectionStatus)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(statusColor)
                        VStack(alignment: .leading, spacing: NetworkSettingsLayout.statusDetailSpacing) {
                            Text(connectionManager.connectionStatus.text(localized: true))
                                .font(CTFont.regular(14))
                                .foregroundStyle(Color.CT.text)
                            if connectionManager.connectionStatus != .connected,
                               let phase = connectionManager.connectingPhase {
                                Text(phase)
                                    .font(CTFont.regular(13))
                                    .foregroundStyle(.orange)
                                    .textSelection(.enabled)
                                    .transition(.opacity)
                            }
                            Text(path.displayDetail)
                                .font(CTFont.regular(13))
                                .foregroundStyle(Color.CT.textDim)
                                .textSelection(.enabled)
                        }

                        Spacer()

                        let displayTransport = streamManager.activeTransport.isEmpty
                            ? streamManager.lastActiveTransport
                            : streamManager.activeTransport
                        let isLive = !streamManager.activeTransport.isEmpty
                        if !displayTransport.isEmpty {
                            // "H3" = legacy native stack; "QUIC" = engine QUIC (construct-transport).
                            let isQUIC = displayTransport == "H3" || displayTransport == "QUIC"
                            // Lock when the live transport is obfuscated QUIC — at-a-glance proof
                            // the direct traffic is DPI-obfuscated. Production ships plain QUIC, so
                            // this only ever shows in DEBUG when obfuscation is explicitly enabled.
                            #if DEBUG
                            let obfuscated = isLive && isQUIC
                                && FeatureFlags.engineQuicExperimental && FeatureFlags.engineQuicObfuscated
                            #else
                            let obfuscated = false
                            #endif
                            HStack(spacing: 4) {
                                if obfuscated {
                                    Image(systemName: "lock.fill").font(.system(size: 10))
                                }
                                Text(isQUIC ? NetworkSettingsLabels.quic : NetworkSettingsLabels.h2)
                                    .font(CTFont.regular(13))
                            }
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

                // MARK: - Traffic Protection (VEIL)
                CTSettingsSectionHeader(title: NSLocalizedString("traffic_protection", comment: "").uppercased())
                CTSectionGroup {
                    // Tri-state mode selector
                    HStack {
                        Text(LocalizedStringKey("veil_title"))
                            .font(CTFont.regular(13))
                            .foregroundColor(Color.CT.textDim)
                        Spacer()
                        CTModeSelector(
                            selection: Binding(
                                get: { veilManager.mode },
                                set: { newMode in
                                    let oldMode = veilManager.mode
                                    veilManager.mode = newMode
                                    switch newMode {
                                    case .off:
                                        veilManager.stop()
                                    case .auto:
                                        // Switching to auto: stop proxy, let DPI detection handle it.
                                        if oldMode == .on { veilManager.stop() }
                                    case .on:
                                        Task { await veilManager.startIfEnabled() }
                                    }
                                }
                            ),
                            options: VeilMode.allCases,
                            labels: [
                                .off:  NSLocalizedString("veil_mode_off", comment: ""),
                                .auto: NSLocalizedString("veil_mode_auto", comment: ""),
                                .on:   NSLocalizedString("veil_mode_on", comment: "")
                            ]
                        )
                    }
                    .padding(.horizontal, NetworkSettingsLayout.rowHorizontalPadding)
                    .padding(.vertical, NetworkSettingsLayout.rowVerticalPadding)

                    if (veilManager.mode != .off || veilManager.isRunning) && hasVeilAccessConfigured {
                        if veilManager.isOnCooldown {
                            CTSep(style: .thin)
                            HStack {
                                Text(LocalizedStringKey("veil_retry"))
                                    .font(CTFont.regular(13))
                                    .foregroundColor(Color.CT.textDim)
                                Spacer()
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundColor(Color.CT.textDim)
                            }
                            .padding(.horizontal, NetworkSettingsLayout.rowHorizontalPadding)
                            .padding(.vertical, NetworkSettingsLayout.rowVerticalPadding)
                        } else if veilManager.isRunning, let relay = veilManager.activeRelay {
                            CTSep(style: .thin)
                            HStack {
                                Text(pathASCII(veilManager.currentTrafficPath))
                                    .font(CTFont.regular(13))
                                    .foregroundColor(pathColor(veilManager.currentTrafficPath))
                                Text(relay.address)
                                    .font(CTFont.regular(NetworkSettingsLayout.relayAddressFontSize))
                                    .foregroundColor(Color.CT.textDim)
                                    .textSelection(.enabled)
                                Spacer()
                                let quality = veilManager.qualityForRelay(relay.address)
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

                        } else if veilManager.mode != .off && !veilManager.isRunning {
                            CTSep(style: .thin)
                            Text(veilManager.lastError ?? NSLocalizedString("veil_establishing", comment: ""))
                                .font(CTFont.regular(11))
                                .foregroundStyle(Color.CT.textDim)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, NetworkSettingsLayout.rowHorizontalPadding)
                                .padding(.vertical, NetworkSettingsLayout.compactRowVerticalPadding)
                        }
                    }
                }

                veilAccessSection

                // QUIC/HTTP-3 transport (construct-transport). For the external release it is
                // always-on and automatic (plain QUIC, falls back to H2 on failure) with no
                // user-facing toggle — confirm it's live via the transport badge in the STATUS
                // section above ("QUIC" when active, "H2" otherwise).
                //
                // The QUIC kill-switch below is visible in DEBUG and on internal TestFlight builds
                // (INTERNAL_TOOLS) so we can A/B QUIC vs H2 across networks; it is compiled out for
                // the external release. The Salamander obfuscation toggle stays DEBUG-only: the
                // production gateway is plain, so enabling obf on a TestFlight build would just get
                // datagrams dropped (invalid CID) and fall back to H2. Direct path only — ignored
                // when VEIL is active.
//                #if DEBUG
                CTSettingsSectionHeader(title: "EXPERIMENTAL", color: .orange)
                CTSectionGroup {
                    Toggle(isOn: $engineQuicOn) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("QUIC / HTTP-3 transport")
                                .font(CTFont.regular(14))
                                .foregroundStyle(.orange)
                            Text("Route the message stream over QUIC instead of H2. Watch the transport badge above to confirm.")
                                .font(CTFont.regular(11))
                                .foregroundStyle(Color.CT.textDim)
                        }
                    }
                    .tint(.orange)
                    .padding(.horizontal, NetworkSettingsLayout.rowHorizontalPadding)
                    .padding(.vertical, NetworkSettingsLayout.compactRowVerticalPadding)
                    .onChange(of: engineQuicOn) { _, newValue in
                        FeatureFlags.engineQuicExperimental = newValue
                        streamManager.reconnectForTransportChange()
                    }

                    #if DEBUG
                    CTSep(style: .thin)

                    // Salamander obfuscation of the QUIC datagrams (DPI-evasion). DEBUG-only —
                    // needs a per-gateway PSK + an obf gateway; against the plain prod gateway it
                    // stays plain / drops.
                    Toggle(isOn: $engineQuicObfOn) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("QUIC obfuscation (Salamander)")
                                .font(CTFont.regular(14))
                                .foregroundStyle(.orange)
                            Text("Obfuscate QUIC datagrams to evade DPI. Needs a provisioned gateway PSK; otherwise stays plain QUIC.")
                                .font(CTFont.regular(11))
                                .foregroundStyle(Color.CT.textDim)
                        }
                    }
                    .tint(.orange)
                    .disabled(!engineQuicOn)
                    .opacity(engineQuicOn ? 1 : 0.4)
                    .padding(.horizontal, NetworkSettingsLayout.rowHorizontalPadding)
                    .padding(.vertical, NetworkSettingsLayout.compactRowVerticalPadding)
                    .onChange(of: engineQuicObfOn) { _, newValue in
                        FeatureFlags.engineQuicObfuscated = newValue
                        streamManager.reconnectForTransportChange()
                    }
                    #endif
                }
//                #endif

                #if DEBUG
                // Debug-only: live FSM diagnostics. Every transport routing decision flows
                // through one place; this screen is that place.
                CTSettingsSectionHeader(title: "DIAGNOSTICS (DEBUG)", color: .orange)
                CTSectionGroup {
                    NavigationLink {
                        TransportDiagnosticsView()
                    } label: {
                        HStack {
                            Text("Transport router state + log")
                                .font(CTFont.regular(13))
                                .foregroundStyle(.orange)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.orange)
                        }
                        .padding(.horizontal, NetworkSettingsLayout.rowHorizontalPadding)
                        .padding(.vertical, NetworkSettingsLayout.compactRowVerticalPadding)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                #endif

                // Footer — mode-specific
                if !hasVeilAccessConfigured {
                    Text(LocalizedStringKey("veil_config_none"))
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, NetworkSettingsLayout.rowHorizontalPadding)
                        .padding(.bottom, NetworkSettingsLayout.footerVerticalPadding)
                } else {
                    Text(LocalizedStringKey(veilFooterKey))
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

    // MARK: - VEIL access (per-user ticket import)

    @ViewBuilder
    private var veilAccessSection: some View {
        CTSettingsSectionHeader(title: NSLocalizedString("veil_config_section", comment: "").uppercased())
        CTSectionGroup {
            HStack {
                if let relay = veilConfiguredRelay {
                    Text(String(format: NSLocalizedString("veil_config_active", comment: ""), relay))
                        .font(CTFont.regular(11))
                        .foregroundColor(Color.CT.accent)
                        .textSelection(.enabled)
                } else {
                    Text(LocalizedStringKey("veil_config_none"))
                        .font(CTFont.regular(11))
                        .foregroundColor(Color.CT.textDim)
                        
                }
            }
            .padding(.horizontal, NetworkSettingsLayout.rowHorizontalPadding)
            .padding(.vertical, NetworkSettingsLayout.rowVerticalPadding)

            CTSep(style: .thin)
            Button { showingVeilScanner = true } label: {
                veilAccessRow(icon: "qrcode.viewfinder", title: NSLocalizedString("veil_config_scan", comment: ""))
            }
            .buttonStyle(.plain)

            CTSep(style: .thin)
            Button { veilPasteText = ""; showingVeilPaste = true } label: {
                veilAccessRow(icon: "doc.on.clipboard", title: NSLocalizedString("veil_config_paste", comment: ""))
            }
            .buttonStyle(.plain)

            if let msg = veilImportMessage {
                CTSep(style: .thin)
                Text(msg)
                    .font(CTFont.regular(11))
                    .foregroundStyle(veilImportIsError ? Color.CT.danger : Color.CT.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, NetworkSettingsLayout.rowHorizontalPadding)
                    .padding(.vertical, NetworkSettingsLayout.compactRowVerticalPadding)
            }
        }
        .sheet(isPresented: $showingVeilScanner) {
            QRScannerView { code in
                showingVeilScanner = false
                handleVeilImport(code)
            }
        }
        .alert(NSLocalizedString("veil_config_paste", comment: ""), isPresented: $showingVeilPaste) {
            TextField(NSLocalizedString("veil_config_paste", comment: ""), text: $veilPasteText)
            Button(NSLocalizedString("veil_config_import", comment: "")) { handleVeilImport(veilPasteText) }
            Button(NSLocalizedString("cancel", comment: ""), role: .cancel) {}
        }
    }

    private func veilAccessRow(icon: String, title: String) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(Color.CT.accent)
            Text(title)
                .font(CTFont.regular(13))
                .foregroundColor(Color.CT.text)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color.CT.textDim)
        }
        .padding(.horizontal, NetworkSettingsLayout.rowHorizontalPadding)
        .padding(.vertical, NetworkSettingsLayout.compactRowVerticalPadding)
        .contentShape(Rectangle())
    }

    private func handleVeilImport(_ text: String) {
        switch VeilConfigImporter.importScannedOrPasted(text) {
        case .success:
            veilImportIsError = false
            veilImportMessage = NSLocalizedString("veil_config_import_ok", comment: "")
            veilTicketRefresh += 1
            // Re-snapshot the relay list so the new ticket is used immediately.
            Task {
                let vm = VeilProxyManager.shared
                if vm.mode != .off { vm.stop(); await vm.startIfEnabled() }
            }
        case .failure(let err):
            veilImportIsError = true
            veilImportMessage = err.localizedDescription
        }
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

    private var veilFooterKey: String {
        switch veilManager.mode {
        case .off:
            // Production ships plain QUIC, so VEIL off == genuinely no obfuscation: tell the truth.
            // In DEBUG, obfuscated QUIC on the direct path IS DPI-evasion, so reflect the live
            // transport when obf is explicitly enabled.
            #if DEBUG
            if FeatureFlags.engineQuicExperimental && FeatureFlags.engineQuicObfuscated {
                let live = streamManager.activeTransport
                // "QUIC"/"H3" live → obfuscated right now; otherwise on the H2 fallback/connecting.
                return (live == "QUIC" || live == "H3")
                    ? "veil_footer_off_obf_active"
                    : "veil_footer_off_obf_fallback"
            }
            #endif
            return "veil_footer_off"
        case .auto: return "veil_footer_auto"
        case .on:   return "veil_footer_on"
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

    private var connectionStatus: String {
        switch connectionManager.connectionStatus {
        case .connected:    return "checkmark.circle.fill"
        case .disconnected: return "xmark.circle.fill"
        case .connecting:   return "arrow.triangle.2.circlepath.circle.fill"
        case .unknown:      return "questionmark.circle.fill"
        }
    }
    
    // TODO: replace with standart SF Symbols
    private func pathASCII(_ path: TrafficPath) -> String {
        switch path {
        case .direct:          return "[→]"
        case .veilFront:        return "[v]"
        case .veilWebTunnel:    return "[ws]"
        case .veilCooldown:     return "[!]"
        case .veilConnecting:   return "[~]"
        }
    }

    private func pathColor(_ path: TrafficPath) -> Color {
        switch path {
        case .direct:          return Color.CT.accentDim
        case .veilFront:        return Color.CT.accent
        case .veilWebTunnel:    return Color.CT.accent
        case .veilCooldown:     return .orange
        case .veilConnecting:   return .orange
        }
    }
}

#Preview {
    NavigationStack {
        NetworkSettingsView()
    }
        .preferredColorScheme(.dark)
}
