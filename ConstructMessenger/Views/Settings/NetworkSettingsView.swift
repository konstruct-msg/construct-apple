//
//  NetworkSettingsView.swift
//  Construct Messenger
//

import SwiftUI

struct NetworkSettingsView: View {
    @ObservedObject private var reachabilityManager = NetworkReachabilityManager.shared
    @ObservedObject private var connectionManager = ConnectionStatusManager.shared

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
            } header: {
                Text("connection")
            }

            // MARK: - Network
            Section {
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
                Text("network_reachability")
            }

            // MARK: - Server
            Section {
                HStack {
                    Text("server")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(grpcHost)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.blue)
                        .textSelection(.enabled)
                }

                HStack {
                    Text("port")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(grpcPort)")
                        .font(.system(size: 13, design: .monospaced))
                        .fontWeight(.medium)
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

    private var grpcHost: String {
        Bundle.main.object(forInfoDictionaryKey: "GRPC_HOST") as? String ?? "ams.konstruct.cc"
    }

    private var grpcPort: Int {
        (Bundle.main.object(forInfoDictionaryKey: "GRPC_PORT") as? String).flatMap(Int.init) ?? 443
    }

    private var connectionTypeDisplayName: String {
        switch reachabilityManager.connectionType {
        case .wifi:       return "Wi-Fi"
        case .cellular:   return "Cellular"
        case .ethernet:   return "Ethernet"
        case .other:      return "Other"
        case .unavailable: return "Unavailable"
        case .unknown:    return "Unknown"
        }
    }
}

#Preview {
    NavigationStack {
        NetworkSettingsView()
    }
}
