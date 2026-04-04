//
//  NetworkSettingsView.swift
//  Construct Messenger
//

import SwiftUI

struct NetworkSettingsView: View {
    private var connectionManager = ConnectionStatusManager.shared
    private var streamManager = MessageStreamManager.shared

    // Custom server (Debug only)
    @State private var customHost = GRPCChannelManager.shared.currentHost
    @State private var customPort = "\(GRPCChannelManager.shared.currentPort)"
    @State private var showingAppliedAlert = false

    // On macOS, ICE is on by default; on iOS, off by default
    @AppStorage(UserDefaultsKey.iceEnabled.key) private var iceEnabled = {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }()
    @StateObject private var iceManager = IceProxyManager.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {

                // MARK: - Connection Status
                CTSettingsSectionHeader(title: NSLocalizedString("status", comment: "").uppercased())
                let path = iceManager.currentTrafficPath
                HStack(spacing: 12) {
                    Text(connectionStatusASCII)
                        .font(CTFont.regular(13))
                        .foregroundColor(statusColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(connectionManager.connectionStatus.displayText)
                            .font(CTFont.regular(13))
                            .foregroundStyle(Color.CT.text)
                        Text(path.displayDetail)
                            .font(CTFont.regular(11))
                            .foregroundStyle(Color.CT.textDim)
                            .textSelection(.enabled)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)

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
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }

                if let error = connectionManager.lastError {
                    CTSep(style: .thin)
                    Text(error)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.CT.danger)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
                CTSep()

                // MARK: - Traffic Protection (ICE)
                CTSettingsSectionHeader(title: NSLocalizedString("traffic_protection", comment: "").uppercased())
                HStack {
                    Text(LocalizedStringKey("ice_title"))
                        .font(CTFont.regular(13))
                        .foregroundColor(iceManager.hasCert ? Color.CT.textDim : Color.CT.textDim.opacity(0.5))
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { iceEnabled },
                        set: { newValue in
                            iceEnabled = newValue
                            iceManager.isEnabled = newValue
                            if newValue {
                                Task { await iceManager.startIfEnabled() }
                            } else {
                                iceManager.stop()
                            }
                        }
                    ))
                    .labelsHidden()
                    .tint(Color.CT.accent)
                    .disabled(!iceManager.hasCert)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)

                if (iceEnabled || iceManager.isRunning) && iceManager.hasCert {
                    if iceManager.isOnCooldown {
                        CTSep(style: .thin)
                        Button {
                            iceManager.clearCooldown()
                        } label: {
                            HStack {
                                Text(LocalizedStringKey("ice_retry"))
                                    .font(CTFont.regular(13))
                                    .foregroundColor(Color.CT.accent)
                                Spacer()
                                Text("[↺]")
                                    .font(CTFont.regular(13))
                                    .foregroundColor(Color.CT.accent)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else if iceManager.isRunning, let relay = iceManager.activeRelay {
                        CTSep(style: .thin)
                        HStack {
                            Text(pathASCII(iceManager.currentTrafficPath))
                                .font(CTFont.regular(13))
                                .foregroundColor(pathColor(iceManager.currentTrafficPath))
                            Text(relay.address)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(Color.CT.textDim)
                                .textSelection(.enabled)
                            Spacer()
                            if relay.tlsServerName != nil {
                                Text("TLS")
                                    .font(CTFont.regular(10))
                                    .foregroundColor(Color.CT.accentDim)
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .overlay(Rectangle().stroke(Color.CT.accent.opacity(0.4), lineWidth: 0.5))
                                Text("obfs4")
                                    .font(CTFont.regular(10))
                                    .foregroundColor(Color.CT.accentDim)
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .overlay(Rectangle().stroke(Color.CT.accent.opacity(0.4), lineWidth: 0.5))
                            } else {
                                Text("obfs4")
                                    .font(CTFont.regular(10))
                                    .foregroundColor(Color.CT.accentDim)
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .overlay(Rectangle().stroke(Color.CT.accent.opacity(0.4), lineWidth: 0.5))
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    } else if !iceManager.isRunning {
                        CTSep(style: .thin)
                        Text(iceManager.lastError ?? NSLocalizedString("ice_unavailable", comment: ""))
                            .font(CTFont.regular(11))
                            .foregroundStyle(Color.CT.textDim)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                    }
                }

                if !iceManager.hasCert {
                    Text(LocalizedStringKey("ice_unavailable"))
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.textDim)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                } else if iceManager.isRunning && !iceEnabled {
                    Text(LocalizedStringKey("ice_auto_activated_footer"))
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.textDim)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                } else {
                    #if os(macOS)
                    (Text(LocalizedStringKey("ice_footer_short")) + Text(" ") + Text("Enabled by default on macOS."))
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.textDim)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                    #else
                    Text(LocalizedStringKey("ice_footer_short"))
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.textDim)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                    #endif
                }
                CTSep()

                // MARK: - Server
                CTSettingsSectionHeader(title: NSLocalizedString("server", comment: "").uppercased())
                HStack {
                    Text(GRPCChannelManager.shared.currentHost)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Color.CT.text)
                        .textSelection(.enabled)
                    Spacer()
                    Text("TLS")
                        .font(CTFont.regular(10))
                        .foregroundColor(Color.CT.accentDim)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .overlay(Rectangle().stroke(Color.CT.accent.opacity(0.4), lineWidth: 0.5))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                CTSep()

                // MARK: - Custom Server (Debug only)
                #if DEBUG
                CTSettingsSectionHeader(title: NSLocalizedString("custom_server_debug", comment: "").uppercased())
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Host (e.g. dev.konstruct.cc)", text: $customHost)
                        #if canImport(UIKit)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                        #endif
                        .textFieldStyle(.roundedBorder)

                    TextField("Port (e.g. 443)", text: $customPort)
                        #if canImport(UIKit)
                        .keyboardType(.numberPad)
                        #endif
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Button(role: .destructive) {
                            GRPCChannelManager.shared.resetToDefaultServer()
                            customHost = GRPCChannelManager.shared.currentHost
                            customPort = "\(GRPCChannelManager.shared.currentPort)"
                        } label: {
                            Text(LocalizedStringKey("reset_to_default"))
                                .font(CTFont.regular(13))
                                .foregroundColor(Color.CT.danger)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(Color.CT.bgMsg)
                                .overlay(Rectangle().stroke(Color.CT.danger.opacity(0.4), lineWidth: 1))
                        }

                        Spacer()

                        Button {
                            applyCustomServer()
                        } label: {
                            Text(LocalizedStringKey("apply_changes"))
                                .font(CTFont.regular(13))
                                .foregroundColor(Color.CT.text)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(Color.CT.bgMsg)
                                .overlay(Rectangle().stroke(Color.CT.accent, lineWidth: 1))
                        }
                        .disabled(customHost.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                Text(LocalizedStringKey("server_settings_footer"))
                    .font(CTFont.regular(11))
                    .foregroundStyle(Color.CT.textDim)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                CTSep()
                #endif
            }
            .padding(.vertical, 20)
        }
        .background(Color.CT.bg.ignoresSafeArea())
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.CT.bgMsg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(NSLocalizedString("network", comment: "").uppercased())
                    .font(CTFont.bold(13))
                    .foregroundStyle(Color.CT.text)
                    .tracking(4)
            }
        }
        .alert("server_applied_title", isPresented: $showingAppliedAlert) {
            Button("ok") { }
        } message: {
            Text("server_applied_message")
        }
    }

    // MARK: - Actions

    private func applyCustomServer() {
        let host = customHost.trimmingCharacters(in: .whitespaces)
        let port = Int(customPort.trimmingCharacters(in: .whitespaces)) ?? 443
        GRPCChannelManager.shared.setCustomServer(host: host, port: port)
        showingAppliedAlert = true
    }

    // MARK: - Helpers

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
        case .direct:        return "[→]"
        case .icePrimary:    return "[t]"
        case .iceRelay:      return "[t]"
        case .iceCooldown:   return "[!]"
        case .iceConnecting: return "[~]"
        }
    }

    private func pathColor(_ path: TrafficPath) -> Color {
        switch path {
        case .direct:        return Color.CT.accentDim
        case .icePrimary:    return Color.CT.accent
        case .iceRelay:      return Color.CT.accentDim
        case .iceCooldown:   return .orange
        case .iceConnecting: return .orange
        }
    }
}

#Preview {
    NavigationStack {
        NetworkSettingsView()
    }
        .preferredColorScheme(.dark)
}
