//
//  NetworkSettingsView.swift
//  Construct Messenger
//

import SwiftUI

struct NetworkSettingsView: View {
    @ObservedObject private var reachabilityManager = NetworkReachabilityManager.shared
    @ObservedObject private var connectionManager = ConnectionStatusManager.shared

    @State private var useCustomServer = GRPCChannelManager.shared.isUsingCustomServer
    @State private var customHost = GRPCChannelManager.shared.isUsingCustomServer
        ? GRPCChannelManager.shared.currentHost : ""
    @State private var customPort = GRPCChannelManager.shared.isUsingCustomServer
        ? "\(GRPCChannelManager.shared.currentPort)" : ""
    @State private var showingAppliedAlert = false

    var body: some View {
        List {
            // MARK: - Stream Status
            Section {
                statusRow(
                    label: NSLocalizedString("status", comment: ""),
                    value: connectionManager.connectionStatus.displayText,
                    color: statusColor
                )

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
                statusRow(
                    label: NSLocalizedString("network_reachability", comment: ""),
                    value: reachabilityManager.isReachable
                        ? NSLocalizedString("reachable", comment: "")
                        : NSLocalizedString("unreachable", comment: ""),
                    color: reachabilityManager.isReachable ? .green : .red
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
                Text("connection")
            }

            // MARK: - Server
            Section {
                HStack {
                    Text("server")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(GRPCChannelManager.shared.currentHost)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(GRPCChannelManager.shared.isUsingCustomServer ? .orange : .blue)
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

                Toggle("use_custom_server", isOn: $useCustomServer)
                    .onChange(of: useCustomServer) { _, enabled in
                        if !enabled {
                            GRPCChannelManager.shared.resetToDefaultServer()
                            customHost = ""
                            customPort = ""
                        } else {
                            customHost = GRPCChannelManager.shared.currentHost
                            customPort = "\(GRPCChannelManager.shared.currentPort)"
                        }
                    }

                if useCustomServer {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Host (e.g. dev.konstruct.cc)", text: $customHost)
                            .autocapitalization(.none)
                            .keyboardType(.URL)
                            .textFieldStyle(.roundedBorder)

                        TextField("Port (e.g. 443)", text: $customPort)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)

                        Button {
                            applyCustomServer()
                        } label: {
                            HStack {
                                Spacer()
                                Text("apply_changes")
                                    .fontWeight(.semibold)
                                Spacer()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(customHost.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                HStack {
                    Text("build_configuration")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(BuildConfiguration.current == .debug ? "Debug" : "Release")
                        .fontWeight(.medium)
                        .foregroundColor(BuildConfiguration.current == .debug ? .orange : .green)
                }
            } header: {
                Text("server_configuration")
            } footer: {
                Text("server_settings_footer")
                    .font(.caption)
            }
        }
        .navigationTitle("network")
        .navigationBarTitleDisplayMode(.inline)
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
        case .connected:    return .green
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
}

#Preview {
    NavigationStack {
        NetworkSettingsView()
    }
}
