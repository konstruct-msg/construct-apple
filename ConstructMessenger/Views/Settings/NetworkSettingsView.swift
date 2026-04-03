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
            VStack(spacing: 20) {

                // MARK: - Connection Status
                ConstructSection(header: NSLocalizedString("status", comment: "").uppercased()) {
                    let path = iceManager.currentTrafficPath
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(statusColor.opacity(0.12))
                                .frame(width: 36, height: 36)
                            Image(systemName: connectionStatusSymbol)
                                .foregroundStyle(statusColor)
                                .font(.system(size: 15, weight: .semibold))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(connectionManager.connectionStatus.displayText)
                                .font(CTFont.bold(16))
                                .foregroundStyle(Color.CT.text)
                            Text(path.displayDetail)
                                .font(CTFont.regular(13))
                                .foregroundStyle(Color.CT.textDim)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    if let heartbeat = streamManager.lastHeartbeatDate {
                        ConstructRowDivider(indent: 16)
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
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }

                    if let error = connectionManager.lastError {
                        ConstructRowDivider(indent: 16)
                        Text(error)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.CT.danger)
                            .textSelection(.enabled)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                }

                // MARK: - Traffic Protection (ICE)
                VStack(alignment: .leading, spacing: 6) {
                    ConstructSection(header: NSLocalizedString("traffic_protection", comment: "").uppercased()) {
                        HStack(spacing: 14) {
                            Image(systemName: "shield.lefthalf.filled")
                                .foregroundStyle(iceEnabled ? Color.CT.accent : Color.CT.textDim)
                                .frame(width: 22, alignment: .center)
                                .font(.system(size: 16))
                            Text(LocalizedStringKey("ice_title"))
                                .font(CTFont.bold(16))
                                .foregroundStyle(iceManager.hasCert ? Color.CT.text : Color.CT.textDim)
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
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)

                        if (iceEnabled || iceManager.isRunning) && iceManager.hasCert {
                            ConstructRowDivider(indent: 52)
                            if iceManager.isOnCooldown {
                                Button {
                                    iceManager.clearCooldown()
                                } label: {
                                    HStack(spacing: 14) {
                                        Image(systemName: "arrow.clockwise")
                                            .foregroundStyle(Color.CT.accent)
                                            .frame(width: 22, alignment: .center)
                                            .font(.system(size: 16))
                                        Text(LocalizedStringKey("ice_retry"))
                                            .font(CTFont.bold(16))
                                            .foregroundStyle(Color.CT.accent)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 14)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            } else if iceManager.isRunning, let relay = iceManager.activeRelay {
                                HStack {
                                    Image(systemName: iceManager.currentTrafficPath.symbolName)
                                        .foregroundColor(pathColor(iceManager.currentTrafficPath))
                                        .frame(width: 16)
                                    Text(relay.address)
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundColor(Color.CT.textDim)
                                        .textSelection(.enabled)
                                    Spacer()
                                    Text(relay.tlsServerName != nil ? "TLS·obfs4" : "obfs4")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundColor(Color.CT.textDim)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Color.CT.noise)
                                        .clipShape(Capsule())
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                            } else if !iceManager.isRunning {
                                Text(iceManager.lastError ?? NSLocalizedString("ice_unavailable", comment: ""))
                                    .font(CTFont.regular(12))
                                    .foregroundStyle(Color.CT.textDim)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                            }
                        }
                    }

                    if !iceManager.hasCert {
                        Text(LocalizedStringKey("ice_unavailable"))
                            .font(CTFont.regular(11))
                            .foregroundStyle(Color.CT.textDim)
                            .padding(.horizontal, 20)
                    } else if iceManager.isRunning && !iceEnabled {
                        Text(LocalizedStringKey("ice_auto_activated_footer"))
                            .font(CTFont.regular(11))
                            .foregroundStyle(Color.CT.textDim)
                            .padding(.horizontal, 20)
                    } else {
                        #if os(macOS)
                        (Text(LocalizedStringKey("ice_footer_short")) + Text(" ") + Text("Enabled by default on macOS."))
                            .font(CTFont.regular(11))
                            .foregroundStyle(Color.CT.textDim)
                            .padding(.horizontal, 20)
                        #else
                        Text(LocalizedStringKey("ice_footer_short"))
                            .font(CTFont.regular(11))
                            .foregroundStyle(Color.CT.textDim)
                            .padding(.horizontal, 20)
                        #endif
                    }
                }

                // MARK: - Server
                ConstructSection(header: NSLocalizedString("server", comment: "").uppercased()) {
                    HStack {
                        Text(GRPCChannelManager.shared.currentHost)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Color.CT.text)
                            .textSelection(.enabled)
                        Spacer()
                        Text(LocalizedStringKey("tls"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.CT.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.CT.accent.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }

                // MARK: - Custom Server (Debug only)
                #if DEBUG
                VStack(alignment: .leading, spacing: 6) {
                    ConstructSection(header: NSLocalizedString("custom_server_debug", comment: "").uppercased()) {
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
                                }
                                .buttonStyle(.bordered)

                                Spacer()

                                Button {
                                    applyCustomServer()
                                } label: {
                                    Text(LocalizedStringKey("apply_changes"))
                                        .fontWeight(.semibold)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(customHost.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                    Text(LocalizedStringKey("server_settings_footer"))
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.textDim)
                        .padding(.horizontal, 20)
                }
                #endif
            }
            .padding(.vertical, 20)
        }
        .background(Color.CT.bg.ignoresSafeArea())
        .navigationTitle("network")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.CT.bgMsg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        #endif
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

    private var connectionStatusSymbol: String {
        switch connectionManager.connectionStatus {
        case .connected:    return "checkmark.circle.fill"
        case .disconnected: return "xmark.circle.fill"
        case .connecting:   return "arrow.triangle.2.circlepath"
        case .unknown:      return "questionmark.circle"
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
}
