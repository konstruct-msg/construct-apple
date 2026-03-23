//
//  DiagnosticsView.swift
//  ConstructMessenger
//
//  In-app log viewer + share sheet for debugging without Xcode.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct DiagnosticsView: View {
    @State private var logText: String = ""
    @State private var logSize: String = ""
    private var push = PushNotificationManager.shared

    var body: some View {
        List {
            // MARK: - Push Notifications
            Section {
                diagRow(
                    label: "Permission",
                    value: push.authorizationStatus.description,
                    ok: push.authorizationStatus == .authorized || push.authorizationStatus == .provisional
                )
                diagRow(
                    label: "APNs Token",
                    value: push.deviceToken != nil ? "received (\(push.deviceToken!.prefix(8))…)" : "missing",
                    ok: push.deviceToken != nil
                )
                diagRow(
                    label: "Registered with server",
                    value: push.isRegisteredWithServer ? "yes" : "no — notifications won't arrive",
                    ok: push.isRegisteredWithServer
                )
            } header: {
                Text("Push Notifications")
            } footer: {
                if !push.isRegisteredWithServer {
                    Text("Token not on server. Go back to chats — registration retries automatically on foreground.")
                        .foregroundStyle(.orange)
                }
            }

            // MARK: - Status
            Section {
                HStack {
                    Label("Log collection", systemImage: "doc.text")
                    Spacer()
                    Text(LogCollector.shared.isEnabled ? "Active" : "Off")
                        .foregroundStyle(LogCollector.shared.isEnabled ? Color.AppStatus.success : .secondary)
                        .font(.footnote)
                }
                if !logSize.isEmpty {
                    HStack {
                        Label("Size", systemImage: "internaldrive")
                        Spacer()
                        Text(logSize).foregroundStyle(.secondary).font(.footnote)
                    }
                }
            }

            // MARK: - Actions
            Section {
                Button {
                    shareArchive()
                } label: {
                    Label("Share logs", systemImage: "square.and.arrow.up")
                }
                .disabled(!LogCollector.shared.isEnabled)

                Button(role: .destructive) {
                    clearLogs()
                } label: {
                    Label("Clear logs", systemImage: "trash")
                }
                .disabled(!LogCollector.shared.isEnabled)
            }

            #if DEBUG
            // MARK: - Dev Tools (Debug only)
            Section {
                Button(role: .destructive) {
                    resetLocalData()
                } label: {
                    Label("Reset local data & Keychain", systemImage: "exclamationmark.triangle")
                }
            } header: {
                Text("Developer")
            } footer: {
                Text("Clears all Keychain keys, sessions and UserDefaults. Use to test fresh registration without reinstalling.")
                    .font(.caption)
            }
            #endif

            // MARK: - Recent Logs
            if !logText.isEmpty {
                Section("Recent logs (tail)") {
                    ScrollView {
                        Text(logText)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4)
                            .textSelection(.enabled)
                    }
                    .frame(height: 340)
                }
            }
        }
        .navigationTitle(LocalizedStringKey("diagnostics"))
        .onAppear { refresh() }
    }

    // MARK: - Helpers

    private func refresh() {
        let bytes = LogCollector.shared.getTotalLogSize()
        if bytes > 0 {
            logSize = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        } else {
            logSize = "empty"
        }

        // Show last ~200 lines of current log
        let files = LogCollector.shared.getAllLogFiles()
        if let first = files.first,
           let raw = try? String(contentsOf: first, encoding: .utf8) {
            let lines = raw.components(separatedBy: "\n")
            logText = lines.suffix(200).joined(separator: "\n")
        }
    }

    private func shareArchive() {
        guard let url = try? LogCollector.shared.createLogArchive() else {
            Log.error("Failed to create log archive", category: "Diagnostics")
            return
        }
#if canImport(UIKit)
        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController {
            root.present(av, animated: true)
        }
#elseif os(macOS)
        NSSharingServicePicker(items: [url])
            .show(relativeTo: .zero, of: NSApp.keyWindow?.contentView ?? NSView(), preferredEdge: .minY)
#endif
    }

    private func clearLogs() {
        LogCollector.shared.clearLogs()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { refresh() }
    }

    private func diagRow(label: String, value: String, ok: Bool) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 5) {
                Circle()
                    .fill(ok ? Color.AppStatus.success : Color.red)
                    .frame(width: 7, height: 7)
                Text(value)
                    .font(.footnote)
                    .foregroundStyle(ok ? Color.primary : Color.red)
            }
        }
    }

    #if DEBUG
    private func resetLocalData() {
        // Wipe Keychain
        KeychainManager.shared.deleteAllKeys()
        // Wipe UserDefaults registration / migration flags
        let keysToRemove = [
            "construct.deviceId", "construct.userId",
            "pqcKyberSPKMigrationV1Done",
            "ice_bridge_cert", "iceActiveRelay", "ice_enabled",
            "recovery_is_setup", "recovery_banner_dismissed",
            "construct.kyber.otpk.nextKeyId",
        ]
        keysToRemove.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        Log.info("🗑️ [DEV] Local data and Keychain wiped", category: "Diagnostics")
    }
    #endif
}

#Preview {
    NavigationStack { DiagnosticsView() }
}
