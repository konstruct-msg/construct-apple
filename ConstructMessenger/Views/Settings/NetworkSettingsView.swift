//
//  NetworkSettingsView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 30.12.2025.
//

import SwiftUI

struct NetworkSettingsView: View {
    @AppStorage(APIConstants.customServerURLKey) private var storedServerURL: String?
    @State private var useCustomServer = false
    @State private var customServerURL = ""
    @State private var showingReconnectAlert = false
    @ObservedObject private var reachabilityManager = NetworkReachabilityManager.shared
    @ObservedObject private var connectionManager = ConnectionStatusManager.shared
    @State private var lastConnectionError: String?
    
    // Computed: Is using custom server?
    private var isUsingCustomServer: Bool {
        storedServerURL != nil && !storedServerURL!.isEmpty
    }

    var body: some View {
        List {
            // MARK: - Connection Status Section
            Section {
                HStack {
                    Text("status")
                        .foregroundColor(.secondary)
                    Spacer()
                    HStack(spacing: 4) {
                        Circle()
                            .fill(connectionManager.isConnected ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(connectionManager.isConnected ? "connected" : connectionManager.connectionStatus.displayText)
                            .fontWeight(.medium)
                    }
                }
                
                // Network Reachability Status
                HStack {
                    Text("network_reachability")
                        .foregroundColor(.secondary)
                    Spacer()
                    HStack(spacing: 4) {
                        Circle()
                            .fill(reachabilityManager.isReachable ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(reachabilityManager.isReachable ? "reachable" : "unreachable")
                            .fontWeight(.medium)
                    }
                }
                
                // Connection Type
                if reachabilityManager.isReachable {
                    HStack {
                        Text("connection_type")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(connectionTypeDisplayName)
                            .fontWeight(.medium)
                    }
                }
                
                // Last Connection Error (if any)
                if let error = lastConnectionError {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("last_error")
                            .foregroundColor(.secondary)
                            .font(.caption)
                        Text(error)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.red)
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("connection")
            }

            // MARK: - Server Configuration Section
            Section {
                // Show current server URL
                VStack(alignment: .leading, spacing: 4) {
                    Text(isUsingCustomServer ? "custom_server" : "default_server")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Text(APIConstants.activeServerURL)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.blue)
                        .textSelection(.enabled)
                }
                
                Toggle("use_custom_server", isOn: $useCustomServer)
                    .onChange(of: useCustomServer) { newValue in
                        if !newValue {
                            // Switching back to default
                            customServerURL = ""
                        } else {
                            // Load existing custom URL if available
                            customServerURL = storedServerURL ?? ""
                        }
                    }

                if useCustomServer {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("custom_server_placeholder", text: $customServerURL)
                            .autocapitalization(.none)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .textFieldStyle(.roundedBorder)

                        Button {
                            saveCustomServer()
                        } label: {
                            HStack {
                                Spacer()
                                Text("apply_changes")
                                    .fontWeight(.semibold)
                                Spacer()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(customServerURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            } header: {
                Text("server_configuration")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if !isUsingCustomServer {
                        Text("Default server from configuration: \(APIConstants.websocketURL)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    if useCustomServer {
                        Text("custom_server_prefix_warning")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            }

            // MARK: - Build Info Section
            Section {
                HStack {
                    Text("build_configuration")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(BuildConfiguration.current == .debug ? "debug" : "release")
                        .fontWeight(.medium)
                        .foregroundColor(BuildConfiguration.current == .debug ? .orange : .green)
                }
            } header: {
                Text("server_information")
            } footer: {
                Text("server_settings_footer")
                    .font(.caption)
            }
        }
        .navigationTitle("network")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Initialize state based on stored value
            useCustomServer = storedServerURL != nil
            customServerURL = storedServerURL ?? ""
            loadLastConnectionError()
        }
        .onChange(of: connectionManager.lastError) { newError in
            lastConnectionError = newError
        }
        .alert("reconnect_required", isPresented: $showingReconnectAlert) {
            Button("ok") { }
        } message: {
            Text("reconnect_alert_message")
        }
    }

    // MARK: - Actions
    private func saveCustomServer() {
        if useCustomServer {
            var url = customServerURL.trimmingCharacters(in: .whitespaces)

            storedServerURL = url
            print("⚠️ Using custom server: \(url)")
        } else {
            storedServerURL = nil
//            print("✅ Reset to default server: \(ServerEnvironment.current.serverURL)")
        }

        // Notify and reconnect
        NotificationCenter.default.post(name: .serverURLChanged, object: nil)
        reconnectToServer()

        showingReconnectAlert = true
    }

    private func reconnectToServer() {
        lastConnectionError = nil
        // For REST architecture, we mark as connecting and let the next API request verify connectivity
        ConnectionStatusManager.shared.markConnecting()
    }
    
    private func loadLastConnectionError() {
        // This is a placeholder - in a real implementation, you might want to store
        // the last error in UserDefaults or a shared state
        lastConnectionError = nil
    }
    
    private var connectionTypeDisplayName: String {
        switch reachabilityManager.connectionType {
        case .wifi:
            return "Wi-Fi"
        case .cellular:
            return "Cellular"
        case .ethernet:
            return "Ethernet"
        case .other:
            return "Other"
        case .unavailable:
            return "Unavailable"
        case .unknown:
            return "Unknown"
        }
    }
}

#Preview {
    NavigationStack {
        NetworkSettingsView()
    }
}
