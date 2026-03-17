//
//  NetworkSettingsView.swift
//  Construct Messenger
//

import SwiftUI

struct NetworkSettingsView: View {
    private var reachabilityManager = NetworkReachabilityManager.shared
    private var connectionManager = ConnectionStatusManager.shared
    private var streamManager = MessageStreamManager.shared

    // Custom server (Debug only)
    @State private var customHost = GRPCChannelManager.shared.currentHost
    @State private var customPort = "\(GRPCChannelManager.shared.currentPort)"
    @State private var showingAppliedAlert = false

    @AppStorage(UserDefaultsKey.iceEnabled.key) private var iceEnabled = false
    @StateObject private var iceManager = IceProxyManager.shared

    var body: some View {
        List {
            // MARK: - Connection Route
            Section {
                let path = iceManager.currentTrafficPath
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(pathColor(path).opacity(0.15))
                            .frame(width: 36, height: 36)
                        Image(systemName: path.symbolName)
                            .foregroundColor(pathColor(path))
                            .font(.system(size: 16, weight: .semibold))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(path.displayTitle)
                            .fontWeight(.semibold)
                        Text(path.displayDetail)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Circle()
                        .fill(pathColor(path))
                        .frame(width: 9, height: 9)
                }
                .padding(.vertical, 4)
            } header: {
                Text("connection_route")
            } footer: {
                Text(connectionRouteFooter(iceManager.currentTrafficPath))
                    .font(.caption)
            }

            Section {
                statusRow(
                    label: NSLocalizedString("status", comment: ""),
                    value: connectionManager.connectionStatus.displayText,
                    color: statusColor
                )

                HStack {
                    Text("subscriptions")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(streamManager.subscriptionUserIds.count)")
                        .fontWeight(.medium)
                        .monospacedDigit()
                }

                if let heartbeat = streamManager.lastHeartbeatDate {
                    HStack {
                        Text("last_heartbeat")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(heartbeat, style: .relative)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                    }
                }

                if let lastSuccess = connectionManager.lastSuccessfulRequest {
                    HStack {
                        Text("last_contact")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(lastSuccess, style: .relative)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                    }
                }

                if let error = connectionManager.lastError {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("last_error")
                            .foregroundColor(.secondary)
                            .font(.caption)
                        Text(error)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.red)
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("grpc_stream")
            }

            // MARK: - Network
            Section {
                statusRow(
                    label: NSLocalizedString("network_reachability", comment: ""),
                    value: reachabilityManager.isReachable
                        ? NSLocalizedString("reachable", comment: "")
                        : NSLocalizedString("unreachable", comment: ""),
                    color: reachabilityManager.isReachable ? Color.AppStatus.success : .red
                )

                if reachabilityManager.isReachable {
                    HStack {
                        Text("connection_type")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(connectionTypeDisplayName)
                            .fontWeight(.medium)
                    }
                }
            } header: {
                Text("network")
            }

            // MARK: - ICE
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
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ice_title")
                            .fontWeight(.medium)
                        Text("ice_subtitle")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .disabled(!iceManager.hasCert)

                if !iceManager.hasCert {
                    Text("ice_unavailable")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if iceEnabled {
                    HStack {
                        Text("status")
                            .foregroundColor(.secondary)
                        Spacer()
                        if iceManager.isRunning {
                            let path = iceManager.currentTrafficPath
                            Label(path.displayTitle, systemImage: path.symbolName)
                                .foregroundColor(pathColor(path))
                                .font(.caption.weight(.semibold))
                        } else {
                            Text(iceManager.lastError ?? "Not connected")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if iceManager.isRunning, let relay = iceManager.activeRelay {
                        HStack {
                            Text("endpoint")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(relay.address)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.primary)
                                .textSelection(.enabled)
                        }
                        HStack {
                            Text("mode")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(relay.tlsServerName != nil ? "TLS + obfs4" : "obfs4 (plain)")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } header: {
                Text("ice_section_header")
            } footer: {
                Text("ice_footer")
                    .font(.caption)
            }

            // MARK: - Server
            Section {
                HStack {
                    Text("server")
                        .foregroundColor(.secondary)
                    Spacer()
                    HStack(spacing: 6) {
                        Text(GRPCChannelManager.shared.currentHost)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.primary)
                        Text("TLS")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(Color.AppStatus.success)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.AppStatus.success.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    .textSelection(.enabled)
                }

                HStack {
                    Text("port")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(GRPCChannelManager.shared.currentPort)")
                        .font(.system(size: 13, design: .monospaced))
                        .fontWeight(.medium)
                }

                HStack {
                    Text("build_configuration")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(BuildConfiguration.current == .debug ? "Debug" : "Release")
                        .fontWeight(.medium)
                        .foregroundColor(BuildConfiguration.current == .debug ? .orange : Color.AppStatus.success)
                }
            } header: {
                Text("server_configuration")
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
                            Text("Reset to default")
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

    private func statusRow(label: String, value: String, color: Color) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(value)
                    .fontWeight(.medium)
            }
        }
    }

    private var statusColor: Color {
        switch connectionManager.connectionStatus {
        case .connected:    return Color.AppStatus.success
        case .disconnected: return .red
        case .connecting:   return .orange
        case .unknown:      return .gray
        }
    }

    private var connectionTypeDisplayName: String {
        switch reachabilityManager.connectionType {
        case .wifi:        return "Wi-Fi"
        case .cellular:    return "Cellular"
        case .ethernet:    return "Ethernet"
        case .other:       return "Other"
        case .unavailable: return "Unavailable"
        case .unknown:     return "Unknown"
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

    private func connectionRouteFooter(_ path: TrafficPath) -> String {
        switch path {
        case .direct:
            return "Traffic goes directly to Construct servers over TLS 1.3. Enable Traffic Protection (ICE) for obfuscation."
        case .icePrimary:
            return "Traffic is obfuscated with obfs4 over TLS. Your ISP sees an HTTPS connection to an ICE endpoint."
        case .iceRelay(let address):
            return "Traffic is obfuscated with obfs4 and forwarded via a relay (\(address)). Your ISP sees a TCP connection to the relay IP only."
        case .iceCooldown:
            return "ICE encountered an error and is temporarily bypassed. Reconnect attempt is in progress."
        case .iceConnecting:
            return "Traffic Protection (ICE) is enabled and the obfs4 proxy is starting."
        }
    }
}

#Preview {
    NavigationStack {
        NetworkSettingsView()
    }
}
