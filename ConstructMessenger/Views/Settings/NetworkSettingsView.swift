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
        List {
            // MARK: - Connection Status
            Section {
                let path = iceManager.currentTrafficPath
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(statusColor.opacity(0.12))
                            .frame(width: 36, height: 36)
                        Image(systemName: connectionStatusSymbol)
                            .foregroundColor(statusColor)
                            .font(.system(size: 15, weight: .semibold))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(connectionManager.connectionStatus.displayText)
                            .fontWeight(.semibold)
                        Text(path.displayDetail)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                }
                .padding(.vertical, 4)

                if let heartbeat = streamManager.lastHeartbeatDate {
                    HStack {
                        Text("last_heartbeat")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(heartbeat, style: .relative)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    .font(.subheadline)
                }

                if let error = connectionManager.lastError {
                    Text(error)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.red)
                        .textSelection(.enabled)
                }
            } header: {
                Text("status")
            }

            // MARK: - Traffic Protection (ICE)
            Section {
                Toggle(isOn: Binding(
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
                )) {
                    Text("ice_title")
                        .fontWeight(.medium)
                }
                .disabled(!iceManager.hasCert)

                if iceEnabled && iceManager.hasCert {
                    if iceManager.isOnCooldown {
                        Button {
                            iceManager.clearCooldown()
                        } label: {
                            Label("ice_retry", systemImage: "arrow.clockwise")
                                .font(.subheadline.weight(.medium))
                        }
                    } else if iceManager.isRunning, let relay = iceManager.activeRelay {
                        HStack {
                            Image(systemName: iceManager.currentTrafficPath.symbolName)
                                .foregroundColor(pathColor(iceManager.currentTrafficPath))
                                .frame(width: 16)
                            Text(relay.address)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                            Spacer()
                            Text(relay.tlsServerName != nil ? "TLS·obfs4" : "obfs4")
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.1))
                                .clipShape(Capsule())
                        }
                    } else if !iceManager.isRunning {
                        Text(iceManager.lastError ?? NSLocalizedString("ice_unavailable", comment: ""))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("traffic_protection")
            } footer: {
                if !iceManager.hasCert {
                    Text("ice_unavailable")
                } else {
                    #if os(macOS)
                    Text("ice_footer_short") + Text(" ") + Text("Enabled by default on macOS.")
                    #else
                    Text("ice_footer_short")
                    #endif
                }
            }

            // MARK: - Server
            Section {
                HStack {
                    Text(GRPCChannelManager.shared.currentHost)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                    Spacer()
                    Text(LocalizedStringKey("tls"))
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(Color.AppStatus.success)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.AppStatus.success.opacity(0.12))
                        .clipShape(Capsule())
                }
            } header: {
                Text("server")
            }

            // MARK: - Custom Server (Debug only)
            #if DEBUG
            Section {
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
                            Text("apply_changes")
                                .fontWeight(.semibold)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(customHost.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            } header: {
                Text("custom_server_debug")
            } footer: {
                Text("server_settings_footer")
                    .font(.caption)
            }
            #endif
        }
        .navigationTitle("network")
        #if canImport(UIKit)
        .navigationBarTitleDisplayMode(.inline)
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
        case .connected:    return Color.AppStatus.success
        case .disconnected: return .red
        case .connecting:   return .orange
        case .unknown:      return .gray
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
        case .direct:        return .blue
        case .icePrimary:    return Color.AppStatus.success
        case .iceRelay:      return .purple
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
