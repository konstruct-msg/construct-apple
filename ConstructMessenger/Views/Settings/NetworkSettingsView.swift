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
                            .fill(WebSocketManager.shared.isConnected ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(WebSocketManager.shared.isConnected ? "connected" : "disconnected")
                            .fontWeight(.medium)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("active_server")
                        .foregroundColor(.secondary)
                    Text(APIConstants.activeServerURL)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.blue)
                }
            } header: {
                Text("connection")
            }

            // MARK: - Server Configuration Section
            Section {
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

                    if useCustomServer {
                        Text("custom_server_prefix_warning")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            }

            // MARK: - Server Info Section
            Section {
                HStack {
                    Text("environment")
                        .foregroundColor(.secondary)
                    Spacer()
//                    Text(ServerEnvironment.current.displayName)
//                        .fontWeight(.medium)
                }

                HStack {
                    Text("build_configuration")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(BuildConfiguration.current == .debug ? "debug" : "release")
                        .fontWeight(.medium)
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

            // Ensure URL has wss:// or ws:// prefix
            if !url.hasPrefix("wss://") && !url.hasPrefix("ws://") {
                url = "wss://" + url
            }

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
        WebSocketManager.shared.disconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            WebSocketManager.shared.connect()
        }
    }
}

#Preview {
    NavigationStack {
        NetworkSettingsView()
    }
}
