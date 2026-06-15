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
    var showNavBar: Bool = true

    init(showNavBar: Bool = true) {
        self.showNavBar = showNavBar
    }

    @Environment(\.dismiss) private var dismiss
    
    @State private var logText: String = ""
    @State private var logSize: String = ""
    @State private var push = PushNotificationManager.shared
    private var isPushPermissionGranted: Bool {
        push.authorizationStatus == .authorized || push.authorizationStatus == .provisional
    }
    private var hasPushToken: Bool {
        push.deviceToken != nil
    }
    private var pushTokenStatusText: String {
        guard let token = push.deviceToken else {
            return NSLocalizedString("diagnostics_apns_token_missing", comment: "")
        }
        let prefix = String(token.prefix(DiagnosticsConfig.apnsTokenPreviewPrefixLength))
        return String(format: NSLocalizedString("diagnostics_apns_token_received_format", comment: ""), prefix)
    }
    private var isLogCollectionEnabled: Bool {
        LogCollector.shared.isEnabled
    }
    private var registrationStatusText: String {
        push.isRegisteredWithServer
        ? NSLocalizedString("diagnostics_yes", comment: "")
        : NSLocalizedString("diagnostics_not_registered_with_server", comment: "")
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: SettingsLayout.sectionSpacing) {
                
                if showNavBar {
                    CTNavBar(
                        title: NSLocalizedString("diagnostics", comment: ""),
                        showBack: true,
                        backAction: { dismiss() }
                    )
                }

                // MARK: - Push Notifications
                VStack(alignment: .leading, spacing: DiagnosticsLayout.sectionHintSpacing) {
                    VStack(alignment: .leading, spacing: 0) {
                        CTSettingsSectionHeader(title: NSLocalizedString("PUSH_NOTIFICATIONS", comment: ""), color: .orange)
                        CTSectionGroup {
                            diagRow(
                                label: NSLocalizedString("diagnostics_permission", comment: ""),
                                value: push.authorizationStatus.description,
                                ok: isPushPermissionGranted
                            )
                            ConstructRowDivider(indent: SettingsLayout.rowDividerIndent)
                            diagRow(
                                label: NSLocalizedString("diagnostics_apns_token", comment: ""),
                                value: pushTokenStatusText,
                                ok: hasPushToken
                            )
                            ConstructRowDivider(indent: SettingsLayout.rowDividerIndent)
                            diagRow(
                                label: NSLocalizedString("diagnostics_registered_with_server", comment: ""),
                                value: registrationStatusText,
                                ok: push.isRegisteredWithServer
                            )
                        }
                    }
                    if !push.isRegisteredWithServer {
                        Text(LocalizedStringKey("diagnostics_server_token_warning"))
                            .font(CTFont.regular(11))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, SettingsLayout.footerHorizontalPadding)
                    }
                }

                // MARK: - Status
                CTSectionGroup {
                    HStack(spacing: SettingsLayout.rowContentSpacing) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isLogCollectionEnabled ? Color.CT.accent : Color.CT.textDim)
                            .lineLimit(1)
                            .fixedSize()
                            .frame(minWidth: SettingsLayout.rowIconMinWidth, alignment: .center)
                        Text(LocalizedStringKey("diagnostics_log_collection"))
                            .font(CTFont.bold(16))
                            .foregroundStyle(Color.CT.text)
                        Spacer()
                        Text(isLogCollectionEnabled
                             ? NSLocalizedString("diagnostics_status_active", comment: "")
                             : NSLocalizedString("diagnostics_status_off", comment: ""))
                            .font(CTFont.regular(14))
                            .foregroundStyle(isLogCollectionEnabled ? Color.CT.accent : Color.CT.textDim)
                    }
                    .padding(.horizontal, SettingsLayout.rowHorizontalPadding)
                    .padding(.vertical, SettingsLayout.rowVerticalPadding)

                    if !logSize.isEmpty {
                        ConstructRowDivider(indent: SettingsLayout.rowDividerIndent)
                        HStack(spacing: SettingsLayout.rowContentSpacing) {
                            Image(systemName: "externaldrive")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.CT.textDim)
                                .lineLimit(1)
                                .fixedSize()
                                .frame(minWidth: SettingsLayout.rowIconMinWidth, alignment: .center)
                            Text(LocalizedStringKey("diagnostics_size"))
                                .font(CTFont.bold(16))
                                .foregroundStyle(Color.CT.text)
                            Spacer()
                            Text(logSize)
                                .font(CTFont.regular(14))
                                .foregroundStyle(Color.CT.textDim)
                        }
                        .padding(.horizontal, SettingsLayout.rowHorizontalPadding)
                        .padding(.vertical, SettingsLayout.rowVerticalPadding)
                    }
                }

                // MARK: - Actions
                CTSectionGroup {
                    
                    ConstructActionRow(systemImage: "square.and.arrow.up", title: LocalizedStringKey("diagnostics_share_logs"), role: .accent) {
                        shareArchive()
                    }

                    ConstructActionRow(systemImage: "trash", title: LocalizedStringKey("diagnostics_clear_logs"), role: .destructive) {
                        clearLogs()
                    }
                    .disabled(!isLogCollectionEnabled)
                    .opacity(isLogCollectionEnabled ? 1 : DiagnosticsLayout.disabledActionOpacity)
                }

                #if DEBUG
                // MARK: - Dev Tools (Debug only)
                VStack(alignment: .leading, spacing: DiagnosticsLayout.sectionHintSpacing) {
                    VStack(alignment: .leading, spacing: 0) {
                        CTSettingsSectionHeader(title: NSLocalizedString("DEVELOPER", comment: ""), color: .orange)
                        CTSectionGroup {
                            ConstructActionRow(systemImage: "arrow.clockwise", title: LocalizedStringKey("diagnostics_force_spk_rotation"), role: .secondary) {
                                Task {
                                    await PreKeyRotationService.shared.forceRotate()
                                }
                            }
                            ConstructActionRow(systemImage: "exclamationmark.triangle", title: LocalizedStringKey("diagnostics_reset_local_data_keychain"), role: .destructive) {
                                resetLocalData()
                            }
                        }
                    }
                    Text(LocalizedStringKey("diagnostics_dev_tools_footer"))
                        .font(CTFont.regular(12))
                        .foregroundStyle(Color.CT.textDim)
                        .padding(.horizontal, SettingsLayout.footerHorizontalPadding)
                }
                #endif

                // MARK: - Recent Logs
                if !logText.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        CTSettingsSectionHeader(title: NSLocalizedString("diagnostics_recent_logs", comment: ""), color: .orange)
                        CTSectionGroup {
                            ScrollView {
                                Text(logText)
                                    .font(CTFont.regular(DiagnosticsLayout.recentLogFontSize))
                                    .foregroundStyle(Color.white)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(DiagnosticsLayout.recentLogPadding)
                                    .textSelection(.enabled)
                            }
                            .frame(height: DiagnosticsConfig.recentLogContainerHeight)
                        }
                    }
                }
            }
            .padding(.vertical, SettingsLayout.screenVerticalPadding)
        }
        .background(Color.CT.bg.ignoresSafeArea())
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.CT.bgMsg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        #endif
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .onAppear { refresh() }
    }

    // MARK: - Helpers

    private func refresh() {
        let bytes = LogCollector.shared.getTotalLogSize()
        if bytes > 0 {
            logSize = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        } else {
            logSize = NSLocalizedString("diagnostics_empty", comment: "")
        }

        let files = LogCollector.shared.getAllLogFiles()
        guard let first = files.first else {
            logText = ""
            return
        }

        DispatchQueue.global(qos: .utility).async {
            let preview = Self.readLogPreview(from: first, lineLimit: DiagnosticsConfig.recentLogLineLimit)
            DispatchQueue.main.async {
                logText = preview
            }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + DiagnosticsConfig.clearLogsRefreshDelay) { refresh() }
    }

    private func diagRow(label: String, value: String, ok: Bool) -> some View {
        HStack(spacing: SettingsLayout.rowContentSpacing) {
            Circle()
                .fill(ok ? Color.CT.accent : Color.CT.danger)
                .frame(width: DiagnosticsLayout.statusDotSize, height: DiagnosticsLayout.statusDotSize)
                .frame(width: SettingsLayout.rowIconMinWidth, alignment: .center)
            Text(label)
                .font(CTFont.bold(16))
                .foregroundStyle(Color.CT.text)
            Spacer()
            Text(value)
                .font(CTFont.regular(13))
                .foregroundStyle(ok ? Color.CT.textDim : Color.CT.danger)
        }
        .padding(.horizontal, SettingsLayout.rowHorizontalPadding)
        .padding(.vertical, SettingsLayout.rowVerticalPadding)
    }

    private static func readLogPreview(from url: URL, lineLimit: Int) -> String {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(lineLimit).joined(separator: "\n")
    }

    #if DEBUG
    private func resetLocalData() {
        // --- Keychain: crypto keys ---
        KeychainManager.shared.deleteAllKeys()       // identity_key, signing_key, crypto_private_keys_json, sessions
        KeychainManager.shared.deleteDeviceKeys()    // deviceId, deviceSigningKey, deviceIdentityKey
        KeychainManager.shared.deleteOtpks()     // crypto_otpks (OTPK bundle)
        KeychainManager.shared.deleteSessionToken()
        KeychainManager.shared.deleteRefreshToken()

        // Kyber SPK — keys are stored under these fixed names in PQCKeyManager
        KeychainManager.shared.deleteData(forKey: "construct.kyber.spk.public")
        KeychainManager.shared.deleteData(forKey: "construct.kyber.spk.secret")
        KeychainManager.shared.deleteData(forKey: "construct.kyber.spk.id")

        // Orchestrator CFE state (session archive index, locks, etc.)
        CryptoManager.shared.clearOrchestratorStateCFE()

        // Clear in-memory session state so the app shows the registration screen
        AuthSessionManager.shared.clearSession()

        // --- UserDefaults: registration / migration flags ---
        let keysToRemove = [
            "construct.deviceId", "construct.userId",
            "pqcKyberSPKMigrationV1Done",
            "ice_bridge_cert", "veilActiveRelay", "ice_enabled",
            "recovery_is_setup", "recovery_banner_dismissed",
            "construct.kyber.otpk.nextKeyId",
        ]
        keysToRemove.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        Log.info("[DEV] Full Keychain + UserDefaults wipe complete (device will re-register on next launch)", category: "Diagnostics")
    }
    #endif
}

#Preview {
    NavigationStack { DiagnosticsView() }
        .preferredColorScheme(.dark)
}
