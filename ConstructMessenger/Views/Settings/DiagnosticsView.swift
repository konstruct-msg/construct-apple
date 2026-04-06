//
//  DiagnosticsView.swift
//  ConstructMessenger
//
//  In-app log viewer + share sheet for debugging without Xcode.
//

import SwiftUI
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

struct DiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    
    @State private var logText: String = ""
    @State private var logSize: String = ""
    private var push = PushNotificationManager.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                
                CTNavBar(
                    title: NSLocalizedString("diagnostics", comment: ""),
                    showBack: true,
                    backAction: { dismiss() }
                )

                // MARK: - Push Notifications
                VStack(alignment: .leading, spacing: 6) {
                    ConstructSection(header: NSLocalizedString("PUSH_NOTIFICATIONS", comment: "")) {
                        diagRow(
                            label: "Permission",
                            value: push.authorizationStatus.description,
                            ok: push.authorizationStatus == .authorized || push.authorizationStatus == .provisional
                        )
                        ConstructRowDivider(indent: 52)
                        diagRow(
                            label: "APNs Token",
                            value: push.deviceToken != nil ? "received (\(push.deviceToken!.prefix(8))…)" : "missing",
                            ok: push.deviceToken != nil
                        )
                        ConstructRowDivider(indent: 52)
                        diagRow(
                            label: "Registered with server",
                            value: push.isRegisteredWithServer ? "yes" : "no — notifications won't arrive",
                            ok: push.isRegisteredWithServer
                        )
                    }
                    if !push.isRegisteredWithServer {
                        Text("Token not on server. Go back to chats — registration retries automatically on foreground.")
                            .font(CTFont.regular(11))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 20)
                    }
                }

                // MARK: - Status
                ConstructSection {
                    HStack(spacing: 14) {
                        Text(CTSymbol.log)
                            .font(CTFont.bold(14))
                            .foregroundStyle(LogCollector.shared.isEnabled ? Color.CT.accent : Color.CT.textDim)
                            .lineLimit(1)
                            .fixedSize()
                            .frame(minWidth: 22, alignment: .center)
                        Text("Log collection")
                            .font(CTFont.bold(16))
                            .foregroundStyle(Color.CT.text)
                        Spacer()
                        Text(LogCollector.shared.isEnabled ? "Active" : "Off")
                            .font(CTFont.regular(14))
                            .foregroundStyle(LogCollector.shared.isEnabled ? Color.CT.accent : Color.CT.textDim)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                    if !logSize.isEmpty {
                        ConstructRowDivider(indent: 52)
                        HStack(spacing: 14) {
                            Text(CTSymbol.disk)
                                .font(CTFont.bold(14))
                                .foregroundStyle(Color.CT.textDim)
                                .lineLimit(1)
                                .fixedSize()
                                .frame(minWidth: 22, alignment: .center)
                            Text("Size")
                                .font(CTFont.bold(16))
                                .foregroundStyle(Color.CT.text)
                            Spacer()
                            Text(logSize)
                                .font(CTFont.regular(14))
                                .foregroundStyle(Color.CT.textDim)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                }

                // MARK: - Actions
                ConstructSection {
                    Button {
                        shareArchive()
                    } label: {
                        HStack(spacing: 14) {
                            Text("[→]")
                                .font(CTFont.bold(14))
                                .foregroundStyle(LogCollector.shared.isEnabled ? Color.CT.accent : Color.CT.textDim)
                                .lineLimit(1)
                                .fixedSize()
                                .frame(minWidth: 22, alignment: .center)
                            Text("Share logs")
                                .font(CTFont.bold(16))
                                .foregroundStyle(LogCollector.shared.isEnabled ? Color.CT.text : Color.CT.textDim)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!LogCollector.shared.isEnabled)
                    .opacity(LogCollector.shared.isEnabled ? 1.0 : 0.4)

                    ConstructRowDivider(indent: 52)

                    ConstructActionRow(icon: "[x]", title: LocalizedStringKey("Clear logs"), role: .destructive) {
                        clearLogs()
                    }
                    .disabled(!LogCollector.shared.isEnabled)
                    .opacity(LogCollector.shared.isEnabled ? 1.0 : 0.4)
                }

                #if DEBUG
                // MARK: - Dev Tools (Debug only)
                VStack(alignment: .leading, spacing: 6) {
                    ConstructSection(header: NSLocalizedString("DEVELOPER", comment: "")) {
                        ConstructActionRow(icon: "[!]", title: LocalizedStringKey("Reset local data & Keychain"), role: .destructive) {
                            resetLocalData()
                        }
                    }
                    Text("Clears all Keychain keys, sessions and UserDefaults. Use to test fresh registration without reinstalling.")
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.textDim)
                        .padding(.horizontal, 20)
                }
                #endif

                // MARK: - Recent Logs
                if !logText.isEmpty {
                    ConstructSection(header: NSLocalizedString("RECENT_LOGS", comment: "")) {
                        ScrollView {
                            Text(logText)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Color.white)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .textSelection(.enabled)
                        }
                        .frame(height: 340)
                    }
                }
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
        .toolbar(.hidden, for: .navigationBar)
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
        HStack(spacing: 14) {
            Circle()
                .fill(ok ? Color.CT.accent : Color.CT.danger)
                .frame(width: 8, height: 8)
                .frame(width: 22, alignment: .center)
            Text(label)
                .font(CTFont.bold(16))
                .foregroundStyle(Color.CT.text)
            Spacer()
            Text(value)
                .font(CTFont.regular(13))
                .foregroundStyle(ok ? Color.CT.textDim : Color.CT.danger)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
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
        .preferredColorScheme(.dark)
}
