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
    #if DEBUG
    @AppStorage("stealth_mode_enabled") private var stealthOverrideEnabled = true
    // Stealth Privacy Pass token diagnostics — snapshotted on refresh (BlindTokenService
    // is not @Observable). Makes an empty wallet diagnosable: shows balance, the last
    // issuance outcome (e.g. "server issuance disabled" when TOKEN_ISSUER_KEY is unset),
    // and the count of sealed sends that went out token-less (anti-abuse degraded).
    @State private var tokenBalance: Int = 0
    @State private var tokenOutcome: String = "—"
    @State private var tokenOutcomeOk: Bool = true
    @State private var tokenlessSends: Int = 0
    // Silent re-init: contacts we currently hold a session with, offered as targets.
    @State private var reinitTargets: [ReinitTarget] = []
    @State private var showReinitPicker = false
    @State private var reinitStatus: String = "—"
    @State private var reinitOk = true

    private struct ReinitTarget: Identifiable {
        let id: String
        let name: String
    }

    // One-shot OTPK pool replace — recovery for pools poisoned before 74b6aff6.
    @State private var otpkReplaceStatus: String = "—"
    @State private var otpkReplaceOk = true
    @State private var isReplacingOtpks = false
    #endif
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
                    ) {
                        EmptyView()
                    } trailing: {
                        EmptyView()
                    }
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
                
                #if DEBUG
                // MARK: - Dev Tools (Debug only)
                VStack(alignment: .leading, spacing: DiagnosticsLayout.sectionHintSpacing) {
                    VStack(alignment: .leading, spacing: 0) {
                        CTSettingsSectionHeader(title: NSLocalizedString("DEVELOPER", comment: ""), color: .orange)
                        CTSectionGroup {
                            Toggle(isOn: $stealthOverrideEnabled) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(LocalizedStringKey("diagnostics_stealth_override_title"))
                                        .font(CTFont.regular(14))
                                        .foregroundStyle(.orange)
                                    Text(LocalizedStringKey("diagnostics_stealth_override_hint"))
                                        .font(CTFont.regular(11))
                                        .foregroundStyle(Color.CT.textDim)
                                }
                            }
                            .tint(.orange)
                            .padding(.horizontal, SettingsLayout.rowHorizontalPadding)
                            .padding(.vertical, SettingsLayout.rowVerticalPadding)
                            ConstructActionRow(systemImage: "arrow.clockwise", title: LocalizedStringKey("diagnostics_force_spk_rotation"), role: .secondary) {
                                Task {
                                    await PreKeyRotationService.shared.forceRotate()
                                }
                            }
                            ConstructActionRow(systemImage: "arrow.triangle.2.circlepath", title: LocalizedStringKey("diagnostics_force_silent_reinit"), role: .secondary) {
                                loadReinitTargets()
                            }
                            ConstructRowDivider(indent: SettingsLayout.rowDividerIndent)
                            diagRow(label: "Last silent re-init", value: reinitStatus, ok: reinitOk)
                            ConstructRowDivider(indent: SettingsLayout.rowDividerIndent)
                            ConstructActionRow(
                                systemImage: "key.horizontal",
                                title: LocalizedStringKey("diagnostics_replace_otpk_pool"),
                                role: .secondary,
                                isLoading: isReplacingOtpks
                            ) {
                                replaceOtpkPool()
                            }
                            ConstructRowDivider(indent: SettingsLayout.rowDividerIndent)
                            diagRow(label: "Last OTPK pool replace", value: otpkReplaceStatus, ok: otpkReplaceOk)
                            ConstructRowDivider(indent: SettingsLayout.rowDividerIndent)
                            ConstructActionRow(systemImage: "exclamationmark.triangle", title: LocalizedStringKey("diagnostics_reset_local_data_keychain"), role: .destructive) {
                                resetLocalData()
                            }
                        }
                    }
                    Text(LocalizedStringKey("diagnostics_silent_reinit_footer"))
                        .font(CTFont.regular(12))
                        .foregroundStyle(Color.CT.textDim)
                        .padding(.horizontal, SettingsLayout.footerHorizontalPadding)
                    Text(LocalizedStringKey("diagnostics_dev_tools_footer"))
                        .font(CTFont.regular(12))
                        .foregroundStyle(Color.CT.textDim)
                        .padding(.horizontal, SettingsLayout.footerHorizontalPadding)
                }

                // MARK: - Stealth Tokens (Debug only)
                VStack(alignment: .leading, spacing: 0) {
                    CTSettingsSectionHeader(title: "STEALTH TOKENS", color: .orange)
                    CTSectionGroup {
                        diagRow(label: "Wallet balance", value: "\(tokenBalance)", ok: tokenBalance > 0)
                        ConstructRowDivider(indent: SettingsLayout.rowDividerIndent)
                        diagRow(label: "Last issuance", value: tokenOutcome, ok: tokenOutcomeOk)
                        ConstructRowDivider(indent: SettingsLayout.rowDividerIndent)
                        diagRow(label: "Token-less sends", value: "\(tokenlessSends)", ok: tokenlessSends == 0)
                    }
                }
                #endif


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
                }

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
                
                // MARK: - Actions
                CTSectionGroup {

                    ConstructActionRow(systemImage: "trash", title: LocalizedStringKey("diagnostics_clear_logs"), role: .destructive) {
                        clearLogs()
                    }
                    .disabled(!isLogCollectionEnabled)
                    .opacity(isLogCollectionEnabled ? 1 : DiagnosticsLayout.disabledActionOpacity)
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
        #if DEBUG
        .confirmationDialog(
            LocalizedStringKey("diagnostics_force_silent_reinit"),
            isPresented: $showReinitPicker,
            titleVisibility: .visible
        ) {
            ForEach(reinitTargets) { target in
                Button(target.name) { forceSilentReinit(target) }
            }
            Button(LocalizedStringKey("cancel"), role: .cancel) {}
        }
        #endif
    }

    // MARK: - Helpers

    private func refresh() {
        #if DEBUG
        refreshStealthTokens()
        #endif
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
        DiagnosticLogShare.present()
    }

    private func clearLogs() {
        // Refresh when the deletion has actually happened, not after a fixed guess at how long it
        // takes. The 0.3 s timer raced the writer queue: under the log volume that makes a user
        // want to clear logs in the first place, it read the size before anything was removed.
        LogCollector.shared.clearLogs { refresh() }
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

    /// Last `lineLimit` lines of a log file, read from the end.
    ///
    /// This used to be `String(contentsOf:)` + `split` + `suffix` — the whole file (up to
    /// `LogCollector.maxFileSize`, 5 MB) decoded into a String and then sliced into ~50 000
    /// Substrings, to keep 200 of them. It ran on every `onAppear` of the screen people open
    /// *because* something is wrong. Now it reads a bounded tail and never touches the rest.
    ///
    /// This is not a claimed fix for the reported crash on leaving Diagnostics — that has no
    /// diagnosis yet and needs the crash report. It is a disproportionate read, fixed on its
    /// own merits.
    private static func readLogPreview(from url: URL, lineLimit: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return "" }

        // Enough for `lineLimit` lines at a generous average width, capped so a file of very long
        // lines cannot pull the old behaviour back in through the window size.
        let window = UInt64(min(DiagnosticsConfig.recentLogTailBytes, Int(end)))
        guard window > 0, (try? handle.seek(toOffset: end - window)) != nil,
              let data = try? handle.readToEnd()
        else { return "" }

        // A window boundary can land mid-character; drop up to 3 leading bytes to find a valid
        // start rather than returning nothing.
        var text: String?
        for skip in 0..<min(4, data.count) where text == nil {
            text = String(data: data.dropFirst(skip), encoding: .utf8)
        }
        guard let text else { return "" }

        // The first line is almost certainly cut in half by the window — drop it unless the
        // window covered the whole file.
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if window < end, !lines.isEmpty { lines.removeFirst() }
        return lines.suffix(lineLimit).joined(separator: "\n")
    }

    #if DEBUG
    private func refreshStealthTokens() {
        tokenBalance = TokenWalletService.shared.balance
        tokenlessSends = PerformanceMetrics.shared.count(event: .stealthTokenlessSend)
        if let outcome = BlindTokenService.shared.lastOutcome {
            if case .ok = outcome { tokenOutcomeOk = true } else { tokenOutcomeOk = false }
            var label = outcome.diagnosticLabel
            if let at = BlindTokenService.shared.lastOutcomeDate {
                let mins = Int(Date().timeIntervalSince(at) / 60)
                label += mins <= 0 ? " (just now)" : " (\(mins)m ago)"
            }
            tokenOutcome = label
        } else {
            tokenOutcome = "no attempt yet"
            tokenOutcomeOk = false
        }
    }

    /// Contacts we currently hold a Double Ratchet session with — the only valid targets, since
    /// the point is to re-init *while the peer still holds the old session*.
    private func loadReinitTargets() {
        let context = PersistenceController.shared.container.viewContext
        let chats = (try? context.fetch(Chat.fetchRequest())) ?? []
        reinitTargets = chats.compactMap { chat in
            guard let user = chat.otherUser, !user.id.isEmpty else { return nil }
            guard CryptoManager.shared.hasSession(for: user.id) else { return nil }
            return ReinitTarget(id: user.id, name: user.resolvedDisplayName)
        }
        if reinitTargets.isEmpty {
            reinitStatus = "no contact has an active session"
            reinitOk = false
        } else {
            showReinitPicker = true
        }
    }

    /// Re-establish our session with `target` as INITIATOR **without telling the peer**.
    ///
    /// This manufactures, on demand, the asymmetry that otherwise only appears by chance: we hold
    /// a fresh ratchet, the peer still holds the old one, so our next message reaches them as an
    /// X3DH carrier (msgNum=0, KEM ciphertext) on a session they already have. That is the input
    /// the core answers with `[ApplyPQContribution, CheckAckInDb]` — two actions — which the host
    /// used to mishandle (see decisions/host-dropped-action-returns).
    ///
    /// `initializeSessionProactively` is exactly the right primitive: it fetches the bundle and
    /// calls `initializeSession(deleteExisting: true)`, and it does NOT send END_SESSION or a
    /// SESSION_RESET_INIT — announcing is the coordinator's job, and announcing is precisely what
    /// we must not do here.
    ///
    /// Send **two** messages afterwards. The first proves the carrier was decrypted; only the
    /// second proves the post-quantum contribution was mixed in symmetrically, because an
    /// asymmetric mix still decrypts msg0 and fails on msg1.
    private func forceSilentReinit(_ target: ReinitTarget) {
        reinitStatus = "re-initialising…"
        reinitOk = true
        Task { @MainActor in
            await SessionInitializationService.shared.initializeSessionProactively(
                userId: target.id,
                onSuccess: {
                    reinitStatus = "OK → \(target.name): now send TWO messages"
                    reinitOk = true
                    Log.info("DIAG[silent_reinit]: re-initialised with \(target.id.prefix(8))… — peer still holds the old session; next send is an X3DH carrier", category: "Diagnostics")
                },
                onFailure: { error in
                    reinitStatus = "failed: \(error.localizedDescription)"
                    reinitOk = false
                    Log.error("DIAG[silent_reinit]: failed for \(target.id.prefix(8))…: \(error)", category: "Diagnostics")
                }
            )
        }
    }

    /// Replace the whole server-side OTPK pool in one shot, and prune the local privates the
    /// replace just retired.
    ///
    /// Recovery, not maintenance. Before `74b6aff6` the append path pruned local privates by id
    /// cutoff while the server retires nothing, so the server still holds public halves whose
    /// privates we deleted. That fix stops new damage; it cannot restore deleted keys. The server
    /// hands out `ORDER BY uploaded_at ASC`, so those dead keys are exactly the ones it serves
    /// next — every one costs a peer a failed 4-DH init and a fall back to 3-DH.
    ///
    /// `replace_existing=true` is the only operation that retires the pool (`key-service` sets
    /// `is_expired` on every live row), which is what makes the poisoned entries unreachable and
    /// what makes the follow-up prune correct here.
    ///
    /// Cost, accepted deliberately: a bundle a peer fetched moments ago is invalidated too, so
    /// their next first-message goes to heal. `pruneGraceWindow` only protects our own side.
    /// Run it once per device, not routinely — see decisions/otpk-pool-lifecycle.
    private func replaceOtpkPool() {
        guard !isReplacingOtpks else { return }
        guard let deviceId = KeychainManager.shared.loadDeviceID(), !deviceId.isEmpty else {
            otpkReplaceStatus = "no device id"
            otpkReplaceOk = false
            return
        }
        isReplacingOtpks = true
        otpkReplaceStatus = "replacing…"
        otpkReplaceOk = true
        Task { @MainActor in
            defer { isReplacingOtpks = false }
            do {
                let uploaded = try await OtpkReplenishmentService.generateAndUpload(
                    count: OtpkReplenishmentService.replenishBatchSize,
                    deviceId: deviceId,
                    replaceExisting: true
                )
                let localCount = CryptoManager.shared.oneTimePrekeyCount()
                otpkReplaceStatus = "OK — \(uploaded) uploaded, \(localCount) local"
                otpkReplaceOk = true
                Log.info(
                    "DIAG[otpk_pool_replaced]: \(uploaded) keys uploaded with replaceExisting, \(localCount) privates held locally — poisoned server entries are now expired",
                    category: "Diagnostics"
                )
            } catch {
                otpkReplaceStatus = "failed: \(error.localizedDescription)"
                otpkReplaceOk = false
                Log.error("DIAG[otpk_pool_replaced]: failed: \(error)", category: "Diagnostics")
            }
        }
    }

    private func resetLocalData() {
        // --- Keychain: crypto keys ---
        KeychainManager.shared.deleteAllKeys()       // identity_key, signing_key, crypto_private_keys_json, sessions
        KeychainManager.shared.deleteDeviceKeys()    // deviceId, deviceSigningKey, deviceIdentityKey
        KeychainManager.shared.deleteOtpks()     // crypto_otpks (OTPK bundle)
        KeychainManager.shared.deleteMlsStore()  // mls_store (MLS group store snapshot)
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
