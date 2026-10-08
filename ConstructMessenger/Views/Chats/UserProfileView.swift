//
//  UserProfileView.swift
//  Construct Messenger
//
//  Unified contact card — shown from Synaps grid AND from Chat header.
//  Visual design matches the Construct dark precision-tool aesthetic.
//
//  Parameters:
//    showMessageButton: false when opened from an active chat (prevents loop)
//    onOpenChat:        closure to open/create chat (nil = no message action)
//    onPrune:           closure to remove contact (nil = action hidden)
//

import SwiftUI
import CoreData

/// Human-readable name of the session's NEGOTIATED crypto suite. Must stay in
/// lockstep with `SuiteID` in construct-core `crypto/suite_id.rs` — the previous
/// hardcode here claimed Kyber for suite 1 (plain classic) and didn't know
/// suite 3 at all.
private func cryptoSuiteName(suiteId: Int) -> String {
    switch suiteId {
    case 1: return "X25519 · ChaCha20-Poly1305"
    case 2: return "PQ Hybrid · X25519+ML-KEM-768 · ML-DSA-65"
    case 3: return "X25519 · ChaCha20-Poly1305 · PQ Ratchet (ML-KEM-768)"
    default: return "Suite \(suiteId)"
    }
}

struct UserProfileView: View {
    private static let profileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    let userId: String

    /// The contact as last saved (`ContactsLive`). A row that is gone — pruned while the card was
    /// open — reads as an empty one rather than taking the card down mid-gesture.
    private var user: ContactRecord {
        ContactsLive.shared.contact(userId) ?? .new(id: userId, isContact: false, addedAt: nil)
    }

    /// Hide "Message" when the card is already opened from inside the chat.
    var showMessageButton: Bool = true
    var onOpenChat: (() -> Void)? = nil
    var onPrune: (() -> Void)? = nil

    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel = ProfileShareViewModel()
    @State private var callManager: (any CallUIManaging)? = CallRuntimeProvider.makeUIManager()
    @State private var showingBlockConfirmation = false
    @State private var showingReportConfirmation = false
    @State private var showingShareAlert = false
    @State private var shareAlertMessage = ""
    @State private var isSharingInProgress = false
    @State private var showAvatarViewer = false
    @State private var showingSafetyNumbers = false
    @State private var hasSession = false
    @State private var sessionSuiteLabel = NSLocalizedString("session_crypto_no_session", comment: "")
    @State private var showingLocalNameEditor = false
    @State private var draftLocalName = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: SettingsLayout.sectionSpacing) {
                    avatarHeader
                    identitySection
                    sharingSection
                    securitySection
                    dangerSection
                }
                .padding(.bottom, 32)
            }
        }
        .background(Color.CT.bg.ignoresSafeArea())
        .screenTitle(NSLocalizedString("profile", comment: ""))
        .onAppear {
            viewModel.setContext(viewContext)
            refreshSessionSecurityState()
        }
        .alert(LocalizedStringKey("block_user_confirmation"), isPresented: $showingBlockConfirmation) {
            Button(LocalizedStringKey("cancel"), role: .cancel) {}
            Button(
                LocalizedStringKey(user.isBlocked ? "unblock" : "block"),
                role: user.isBlocked ? .none : .destructive
            ) { handleBlockToggle() }
        } message: {
            Text(LocalizedStringKey(user.isBlocked ? "unblock_user_confirmation_message" : "block_user_confirmation_message"))
        }
        .alert(LocalizedStringKey("report_spam_confirmation"), isPresented: $showingReportConfirmation) {
            Button(LocalizedStringKey("cancel"), role: .cancel) {}
            Button(LocalizedStringKey("report_spam"), role: .destructive) { handleReportSpam() }
        } message: {
            Text(LocalizedStringKey("report_spam_confirmation_message"))
        }
        .alert(LocalizedStringKey("share_my_data_alert"), isPresented: $showingShareAlert) {
            Button(LocalizedStringKey("ok")) {}
        } message: {
            Text(shareAlertMessage)
        }
        .sheet(isPresented: $showingSafetyNumbers) {
            // Empty when no device is pinned yet: the view says the number is unavailable.
            SafetyNumberView(
                theirDeviceIds: KeyChangeUX.safetyDeviceIds(ofContact: userId),
                theirDisplayName: user.resolvedDisplayName
            )
            .sheetNavigation()
        }
        .alert(LocalizedStringKey("local_name"), isPresented: $showingLocalNameEditor) {
            TextField(NSLocalizedString("local_name_placeholder", comment: ""), text: $draftLocalName)
            Button(LocalizedStringKey("save")) { saveLocalName() }
            if !(user.localAlias ?? "").isEmpty {
                Button(LocalizedStringKey("local_name_clear"), role: .destructive) { clearLocalName() }
            }
            Button(LocalizedStringKey("cancel"), role: .cancel) {}
        } message: {
            Text(LocalizedStringKey("local_name_footer"))
        }
    }

    // MARK: - Avatar header

    private var avatarHeader: some View {
        let avatarImage: PlatformImage? = user.avatar.flatMap { PlatformImage(data: $0) }
        return VStack(spacing: 14) {
            MainAvatarView(
                userId: user.id,
                displayName: user.resolvedDisplayName,
                image: avatarImage,
                size: 96,
                isActive: false
            )
            // Tap to view the avatar full-screen (only when there is an image).
            .contentShape(Rectangle())
            .onTapGesture { if avatarImage != nil { showAvatarViewer = true } }

            VStack(spacing: 4) {
                Text(user.resolvedDisplayName)
                    .font(CTFont.title)
                    .foregroundStyle(Color.CT.text)
                    .multilineTextAlignment(.center)
                if !user.username.isEmpty {
                    Text("@\(user.username)")
                        .font(CTFont.secondary)
                        .foregroundStyle(Color.CT.textDim)
                }
            }

            if user.isBlocked {
                HStack(spacing: 5) {
                    Image(systemName: "nosign")
                        .font(CTIcon.font(CTIcon.caption, weight: .semibold))
                        .accessibilityHidden(true)
                    Text(NSLocalizedString("profile_blocked_badge", comment: ""))
                        .font(CTFont.ui(11, weight: .semibold, relativeTo: .caption2))
                }
                .foregroundStyle(Color.CT.danger)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.CT.danger.opacity(0.14), in: CTShape.badge())
            }

            if !actionButtons.isEmpty {
                actionButtonRow.padding(.top, CTLayout.inlinePad)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .sheet(isPresented: $showAvatarViewer) {
            if let avatarImage {
                FullScreenImageView(image: avatarImage, isPresented: $showAvatarViewer)
            }
        }
    }

    // MARK: - Identity section

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            CTSettingsSectionHeader(title: NSLocalizedString("identity_section", comment: ""))

            CTSectionGroup {

            // Local-only alias the user assigns. Never leaves the device; overrides the
            // resolved display name everywhere (chat list, header, call screens).
            Button {
                draftLocalName = user.localAlias ?? ""
                showingLocalNameEditor = true
            } label: {
                profileRow(label: NSLocalizedString("local_name", comment: "")) {
                    HStack(spacing: 8) {
                        let hasAlias = !(user.localAlias ?? "").isEmpty
                        Text(hasAlias ? (user.localAlias ?? "") : NSLocalizedString("local_name_unset", comment: ""))
                            .font(CTFont.ui(14))
                            .foregroundStyle(hasAlias ? Color.CT.text : Color.CT.textDim)
                        Image(systemName: "pencil")
                            .font(CTIcon.font(CTIcon.caption, weight: .semibold))
                            .foregroundStyle(Color.CT.accent.opacity(0.7))
                    }
                }
            }
            .buttonStyle(.plain)
            ConstructRowDivider(indent: 20)

            // External identity = key fingerprint (thread 5.3). UUID is internal addressing only.
            if let fp = user.knownIdentityKey.flatMap({ IdentityFingerprint.short(from: $0) }) {
                Button {
                    PlatformClipboard.copy(fp)
                } label: {
                    profileRow(label: NSLocalizedString("identity_fingerprint", comment: "")) {
                        HStack(spacing: 6) {
                            Text(fp)
                                .font(CTFont.mono(12))
                                .foregroundStyle(Color.CT.accent)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Image(systemName: "doc.on.doc")
                                .font(CTIcon.font(CTIcon.caption, weight: .regular))
                                .foregroundStyle(Color.CT.textDim)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("identity_fingerprint", comment: ""))
                .accessibilityHint(NSLocalizedString("identity_fingerprint_copy_hint", comment: ""))
            } else {
                profileRow(label: NSLocalizedString("identity_fingerprint", comment: "")) {
                    Text(NSLocalizedString("identity_fingerprint_unknown", comment: ""))
                        .font(CTFont.body)
                        .foregroundStyle(Color.CT.textDim)
                }
            }
            // Internal ServerUserId kept off the primary identity surface (addressing only).
            #if DEBUG
            ConstructRowDivider(indent: 20)
            profileRow(label: NSLocalizedString("user_id", comment: "")) {
                let uid = user.id
                let short = uid.count > 12 ? "\(uid.prefix(8))...\(uid.suffix(2))" : uid
                Text(short)
                    .font(CTFont.mono(13))
                    .foregroundStyle(Color.CT.textDim.opacity(0.7))
            }
            #endif
            }
        }
    }

    // MARK: - Actions

    /// What the card can start right away, as the system's contact cards show it: a row of round
    /// buttons under the name (owner, 2026-10-08, TODO 130). Message only when the card is not
    /// opened from the chat itself; calls only when a call can start — no greyed-out rows.
    private enum ContactAction: Hashable { case message, call, video }

    private var actionButtons: [ContactAction] {
        var actions: [ContactAction] = []
        if showMessageButton, onOpenChat != nil { actions.append(.message) }
        if CallsFeature.isEnabled, let callManager, case .idle = callManager.state {
            actions.append(.call)
            if CallsFeature.isVideoEnabled { actions.append(.video) }
        }
        return actions
    }

    private var actionButtonRow: some View {
        HStack(spacing: CTLayout.sectionGap) {
            ForEach(actionButtons, id: \.self) { action in
                switch action {
                case .message:
                    ContactActionButton(titleKey: "message", systemImage: "message") {
                        onOpenChat?(); dismiss()
                    }
                case .call:
                    ContactActionButton(titleKey: "chat_action_call", systemImage: "phone") {
                        startCall(hasVideo: false)
                    }
                case .video:
                    ContactActionButton(titleKey: "chat_action_video", systemImage: "video") {
                        startCall(hasVideo: true)
                    }
                }
            }
        }
    }

    private func startCall(hasVideo: Bool) {
        guard let callManager else { return }
        Task {
            await callManager.startOutgoingCall(
                to: user.id,
                displayName: user.resolvedDisplayName,
                hasVideo: hasVideo
            )
        }
        dismiss()
    }

    // MARK: - Sharing section

    /// Whether this person gets my name and photo — a state, so a switch, not a button whose
    /// title flips between "share" and "stop sharing".
    private var sharingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            CTSettingsSectionHeader(title: NSLocalizedString("profile_sharing_section", comment: ""))

            CTSectionGroup {

            Toggle(isOn: Binding(
                get: { user.amISharingWith },
                set: { handleShareToggle($0) }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(NSLocalizedString("share_my_profile", comment: ""))
                        .font(CTFont.ui(14))
                        .foregroundStyle(Color.CT.text)
                    Text(NSLocalizedString("share_profile_explanation", comment: ""))
                        .font(CTFont.caption)
                        .foregroundStyle(Color.CT.textDim)
                }
            }
            .tint(Color.CT.accent)
            .disabled(isSharingInProgress)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            if let sharedAt = user.sharedWithMeAt, user.isSharingWithMe {
                ConstructRowDivider(indent: 20)
                Text(String(format: NSLocalizedString("sharing_with_you", comment: ""), formatDate(sharedAt)))
                    .font(CTFont.caption)
                    .foregroundStyle(Color.CT.textDim)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            }
        }
    }

    // MARK: - Security / Crypto section

    private var securitySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            CTSettingsSectionHeader(title: NSLocalizedString("security", comment: ""))

            CTSectionGroup {

            if let alert = user.trustAlert {
                keyChangeWarningBlock(alert)
                ConstructRowDivider(indent: 20)
            }

            // One row: the state, said with a badge and a word, and the negotiated suite under it.
            // It was two rows — a badge alone, then the suite as a row with no label.
            VStack(alignment: .leading, spacing: 0) {
                profileRow(label: NSLocalizedString("session_crypto_suite", comment: "")) {
                    HStack(spacing: 6) {
                        CTStatusBadge(status: hasSession ? .ok : .off, size: 13)
                        Text(hasSession ? NSLocalizedString("encrypted", comment: "") : sessionSuiteLabel)
                            .font(CTFont.ui(13, relativeTo: .footnote))
                            .foregroundStyle(hasSession ? Color.CT.text : Color.CT.textDim)
                    }
                }
                if hasSession {
                    Text(sessionSuiteLabel)
                        .font(CTFont.mono(11))
                        .foregroundStyle(Color.CT.textDim)
                        .padding(.horizontal, 20)
                        .padding(.top, -6)
                        .padding(.bottom, 12)
                }
            }
            ConstructRowDivider(indent: 20)

            Button {
                showingSafetyNumbers = true
            } label: {
                profileRow(label: NSLocalizedString("safety_numbers", comment: "")) {
                    Image(systemName: "chevron.right")
                        .font(CTIcon.font(CTIcon.caption, weight: .semibold))
                        .foregroundStyle(Color.CT.textDim)
                }
            }
            .buttonStyle(.plain)
            }
        }
    }

    /// Persistent trust warning until the user verifies or acknowledges it.
    private func keyChangeWarningBlock(_ alert: ContactTrustAlert) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(Color.CT.danger)
                Text(NSLocalizedString(alert.titleKey, comment: ""))
                .font(CTFont.ui(12, weight: .bold))
                .foregroundStyle(Color.CT.danger)
            }

            Text(alert.subtitle(contactName: user.resolvedDisplayName))
            .font(CTFont.caption)
            .foregroundStyle(Color.CT.textDim)

            HStack(spacing: 10) {
                CTButton(label: NSLocalizedString("key_change_verify", comment: ""), role: .destructive) {
                    showingSafetyNumbers = true
                }
                CTButton(label: NSLocalizedString("security_notice_acknowledge", comment: ""), role: .secondary) {
                    _ = KeyChangeUX.acknowledgeKeyChange(userId: user.id)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.CT.danger.opacity(0.08))
    }

    // MARK: - Danger section

    private var dangerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            CTSettingsSectionHeader(title: NSLocalizedString("danger_zone", comment: ""), color: Color.CT.danger)

            CTSectionGroup {

            actionRow(
                label: NSLocalizedString(user.isBlocked ? "unblock_user" : "block_user", comment: ""),
                color: user.isBlocked ? Color.CT.text : Color.CT.danger
            ) { showingBlockConfirmation = true }
            ConstructRowDivider(indent: 20)

            actionRow(
                label: NSLocalizedString("report_spam", comment: ""),
                color: Color.CT.danger
            ) { showingReportConfirmation = true }

            if let prune = onPrune {
                ConstructRowDivider(indent: 20)
                actionRow(label: NSLocalizedString("synapses_prune_action", comment: ""), color: Color.CT.danger) {
                    prune(); dismiss()
                }
            }
            }
        }
    }

    // MARK: - Layout helpers

    private func profileRow<V: View>(label: String, @ViewBuilder value: () -> V) -> some View {
        HStack {
            if !label.isEmpty {
                Text(label)
                    .font(CTFont.ui(14))
                    .foregroundStyle(Color.CT.textDim)
            }
            Spacer()
            value()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func actionRow(label: String, color: Color, isLoading: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: { guard !isLoading else { return }; action() }) {
            HStack {
                Text(label)
                    .font(CTFont.ui(14))
                    .foregroundStyle(color)
                Spacer()
                if isLoading {
                    ProgressView().scaleEffect(0.75).tint(Color.CT.textDim)
                } else {
                    Image(systemName: "chevron.right")
                        .font(CTFont.body)
                        .foregroundStyle(color.opacity(0.6))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }

    // MARK: - Helpers

    private func formatDate(_ date: Date) -> String {
        Self.profileDateFormatter.string(from: date)
    }

    private func refreshSessionSecurityState() {
        let sessionExists = SessionLifecycleController.shared.hasActiveSession(for: user.id)
        // Real negotiated suite from the Rust core (Keychain only as fallback) —
        // suite 3 is negotiated per-session and never appears in the peer's bundle.
        let suiteId = Int(CryptoManager.shared.sessionSuiteIdAcrossDevices(ofPeer: user.id))
        hasSession = sessionExists
        if sessionExists && suiteId > 0 {
            var label = cryptoSuiteName(suiteId: suiteId)
            // A session opened before PQXDH v2 has no ML-KEM in its first key (or only the old
            // deferred contribution) until the upgrade sweep replaces it. The core's health report
            // says which, per device; the Keychain flag this read before is gone with the path
            // that set it.
            let preV2 = SessionAddressing.deviceIds(ofPeer: user.id).contains { device in
                CryptoManager.shared.getSessionHealth(for: device).map { $0.pqHandshake != .initialV2 } ?? false
            }
            if preV2 {
                label += " · PQXDH degraded"
            }
            sessionSuiteLabel = label
        } else {
            sessionSuiteLabel = NSLocalizedString("session_crypto_no_session", comment: "")
        }
    }

    private func handleShareToggle(_ share: Bool) {
        guard !isSharingInProgress else { return }
        if share {
            isSharingInProgress = true
            viewModel.shareProfile(with: user.id) { success, error in
                isSharingInProgress = false
                if success {
                    write { try $0.setSharingWith(userId, true) }
                    shareAlertMessage = NSLocalizedString("profile_shared_successfully", comment: "")
                } else {
                    shareAlertMessage = error ?? NSLocalizedString("failed_to_share_profile", comment: "")
                }
                showingShareAlert = true
            }
        } else {
            write { try $0.setSharingWith(userId, false) }
            shareAlertMessage = NSLocalizedString("profile_sharing_stopped", comment: "")
            showingShareAlert = true
        }
    }

    /// Report the contact for spam and block them. Reporting feeds the server-side
    /// auto-escalation (flag/ban) engine; we also block (report-and-block is the safe default —
    /// you should not keep receiving messages from someone you reported). The reported device id
    /// is derived locally from the peer's identity key (`SHA256(identity_public)[0..16]`, the same
    /// value the server keys sentinel on), so it works even under sealed sender.
    private func handleReportSpam() {
        let reportedDeviceId: String? = user.knownIdentityKey.map { deriveDeviceId(identityPublicKey: $0) }

        // Block immediately (local drop + durable server-side); report best-effort alongside.
        write { try $0.setBlocked(userId, true) }

        Task {
            var reported = false
            if let reportedDeviceId, !reportedDeviceId.isEmpty {
                do {
                    reported = try await SentinelServiceClient.shared.reportSpam(reportedDeviceId: reportedDeviceId)
                } catch {
                    Log.error("reportSpam failed for \(userId.prefix(8))…: \(error)", category: "UserProfileView")
                }
            } else {
                Log.error("reportSpam skipped for \(userId.prefix(8))… — no known identity key to derive device id", category: "UserProfileView")
            }
            do { _ = try await UserServiceClient.shared.blockUser(userId: userId, reason: "spam") }
            catch { Log.error("Block sync failed after report for \(userId.prefix(8))…: \(error)", category: "UserProfileView") }

            await MainActor.run {
                shareAlertMessage = NSLocalizedString(reported ? "report_spam_success" : "report_spam_failed", comment: "")
                showingShareAlert = true
            }
        }
    }

    private func handleBlockToggle() {
        let nowBlocked = !user.isBlocked
        write { try $0.setBlocked(userId, nowBlocked) }
        // Persist the block server-side (durable across reinstall; the authoritative
        // `user_blocks` row used on the identified path). The local `isBlocked` already drives
        // the client-side drop, so a failed RPC must NOT revert the local state — best-effort sync.
        Task {
            do {
                if nowBlocked {
                    _ = try await UserServiceClient.shared.blockUser(userId: userId)
                } else {
                    _ = try await UserServiceClient.shared.unblockUser(userId: userId)
                }
            } catch {
                Log.error("Block sync failed for \(userId.prefix(8))… (local state kept): \(error)", category: "UserProfileView")
            }
        }
    }

    /// Persist the local alias. Empty/whitespace clears it (falls back to the resolved name).
    private func saveLocalName() {
        let trimmed = draftLocalName.trimmingCharacters(in: .whitespacesAndNewlines)
        write { try $0.setAlias(userId, trimmed.isEmpty ? nil : trimmed) }
    }

    private func clearLocalName() {
        write { try $0.setAlias(userId, nil) }
    }

    private func write(_ change: (any ContactStore) throws -> Bool) {
        do {
            _ = try change(LocalRepositories.contacts)
        } catch {
            Log.error("Contact \(userId.prefix(8))… not saved: \(error)", category: "UserProfileView")
        }
    }
}

// MARK: - Preview

#Preview {
    let container = PreviewHelpers.createPreviewContainer()
    ContactsLive.useForPreview(container)
    let context = container.viewContext
    let user = PreviewHelpers.createSampleUser(context: context, id: "user1", username: "alice", displayName: "Alice Wonderland")
    user.isContact = true
    try? context.save()

    return UserProfileView(
        userId: user.id,
        showMessageButton: true,
        onOpenChat: {},
        onPrune: {}
    )
    .environment(\.managedObjectContext, context)
}

#Preview {
    let container = PreviewHelpers.createPreviewContainer()
    ContactsLive.useForPreview(container)
    let context = container.viewContext
    let user = PreviewHelpers.createSampleUser(context: context, id: "user1", username: "alice", displayName: "Alice")
    try? context.save()
    return UserProfileView(userId: user.id)
        .environment(\.managedObjectContext, context)
}

/// One of the contact card's round actions: the system's glass circle with a symbol, the title
/// under it — as the iOS 26 contact cards draw them. The title is part of the button.
private struct ContactActionButton: View {
    let titleKey: String
    let systemImage: String
    let action: () -> Void

    private let diameter: CGFloat = 52

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                circle
                Text(NSLocalizedString(titleKey, comment: ""))
                    .font(CTFont.caption)
                    .foregroundStyle(Color.CT.text)
                    .lineLimit(1)
            }
            .frame(minWidth: CTLayout.hitTarget + CTLayout.sectionGap)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var circle: some View {
        let icon = Image(systemName: systemImage)
            .font(CTIcon.font(CTIcon.nav))
            .foregroundStyle(Color.CT.accent)
            .frame(width: diameter, height: diameter)
        if #available(iOS 26.0, macOS 26.0, *) {
            icon.glassEffect(.regular.interactive(), in: Circle())
        } else {
            icon.background(Color.CT.bgMsg, in: Circle())
        }
    }
}
