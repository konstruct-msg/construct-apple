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
                    Text("Status")
                        .foregroundColor(.secondary)
                    Spacer()
                    HStack(spacing: 4) {
                        Circle()
                            .fill(WebSocketManager.shared.isConnected ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(WebSocketManager.shared.isConnected ? "Connected" : "Disconnected")
                            .fontWeight(.medium)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Active Server")
                        .foregroundColor(.secondary)
                    Text(APIConstants.activeServerURL)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.blue)
                }
            } header: {
                Text("Connection")
            }

            // MARK: - Server Configuration Section
            Section {
                Toggle("Use Custom Server", isOn: $useCustomServer)
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
                        TextField("wss://your-server.com", text: $customServerURL)
                            .autocapitalization(.none)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .textFieldStyle(.roundedBorder)

                        Button {
                            saveCustomServer()
                        } label: {
                            HStack {
                                Spacer()
                                Text("Apply Changes")
                                    .fontWeight(.semibold)
                                Spacer()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(customServerURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            } header: {
                Text("Server Configuration")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {

                    if useCustomServer {
                        Text("Custom server address must start with wss:// or ws://")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            }

            // MARK: - Server Info Section
            Section {
                HStack {
                    Text("Environment")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(ServerEnvironment.current.displayName)
                        .fontWeight(.medium)
                }

                HStack {
                    Text("Build Configuration")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(BuildConfiguration.current == .debug ? "Debug" : "Release")
                        .fontWeight(.medium)
                }
            } header: {
                Text("Server Information")
            } footer: {
                Text("These settings are automatically configured based on your build configuration.")
                    .font(.caption)
            }
        }
        .navigationTitle("Network")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Initialize state based on stored value
            useCustomServer = storedServerURL != nil
            customServerURL = storedServerURL ?? ""
        }
        .alert("Reconnect Required", isPresented: $showingReconnectAlert) {
            Button("OK") { }
        } message: {
            Text("The app will reconnect to the new server.")
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
            print("✅ Reset to default server: \(ServerEnvironment.current.serverURL)")
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
