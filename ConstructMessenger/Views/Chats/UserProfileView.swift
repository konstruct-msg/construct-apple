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

/// Maps a numeric suite ID (as stored in UserDefaults) to a human-readable name.
private func cryptoSuiteName(suiteId: Int) -> String {
    switch suiteId {
    case 1: return "X25519 + Kyber768"
    case 2: return "X25519 + Kyber1024"
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

    @ObservedObject var user: User

    /// Hide "Message" when the card is already opened from inside the chat.
    var showMessageButton: Bool = true
    var onOpenChat: (() -> Void)? = nil
    var onPrune: (() -> Void)? = nil

    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel = ProfileShareViewModel()
    @State private var callManager = CallManager.shared
    @State private var showingBlockConfirmation = false
    @State private var showResetSessionConfirm = false
    @State private var showingShareAlert = false
    @State private var shareAlertMessage = ""
    @State private var isSharingInProgress = false
    @State private var showingSafetyNumbers = false
    @State private var hasSession = false
    @State private var sessionSuiteLabel = NSLocalizedString("session_crypto_no_session", comment: "")

    var body: some View {
        VStack(spacing: 0) {
            CTNavBar(
                title: NSLocalizedString("profile", comment: ""),
                showBack: true,
                backAction: { dismiss() }
            )
            flatDivider(thick: true)

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    avatarHeader
                    flatDivider(thick: true)
                    identitySection
                    flatDivider(thick: true)
                    actionsSection
                    flatDivider(thick: true)
                    securitySection
                    flatDivider(thick: true)
                    dangerSection
                    flatDivider(thick: true)

                    Text("> \(NSLocalizedString("end_to_end_encrypted", comment: ""))")
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.accent.opacity(0.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                }
                .padding(.bottom, 32)
            }
        }
        .background(Color.CT.bg.ignoresSafeArea())
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
        .alert(LocalizedStringKey("share_my_data_alert"), isPresented: $showingShareAlert) {
            Button(LocalizedStringKey("ok")) {}
        } message: {
            Text(shareAlertMessage)
        }
        .confirmationDialog(
            LocalizedStringKey("reset_session_title"),
            isPresented: $showResetSessionConfirm,
            titleVisibility: .visible
        ) {
            Button(LocalizedStringKey("reset_session"), role: .destructive) {
                Task {
                    do {
                        try await SessionLifecycleController.shared.sendEndSession(to: user.id, reason: "user_requested")
                    } catch {
                        Log.error("Failed to send user-requested END_SESSION for \(user.id.prefix(8))…: \(error)", category: "UserProfileView")
                    }
                }
            }
            Button(LocalizedStringKey("cancel"), role: .cancel) {}
        } message: {
            Text(LocalizedStringKey("reset_session_message"))
        }
        .sheet(isPresented: $showingSafetyNumbers) {
            SafetyNumberView(
                theirDeviceId: user.id,
                theirDisplayName: user.resolvedDisplayName
            )
        }
    }

    // MARK: - Avatar header

    private var avatarHeader: some View {
        let avatarImage: PlatformImage? = user.avatarData.flatMap { PlatformImage(data: $0) }
        return VStack(spacing: 14) {
            MainAvatarView(
                userId: user.id,
                displayName: user.resolvedDisplayName,
                image: avatarImage,
                size: 96,
                isActive: false
            )

            if user.isBlocked {
                Text("[ BLOCKED ]")
                    .font(CTFont.bold(10))
                    .foregroundStyle(Color.CT.danger)
                    .tracking(2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    // MARK: - Identity section

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(NSLocalizedString("identity_section", comment: ""))
            flatRowDivider()

            profileRow(label: NSLocalizedString("username", comment: "")) {
                Text("<@\(user.username.isEmpty ? "—" : user.username)>")
                    .font(CTFont.regular(14))
                    .foregroundStyle(Color.CT.textDim)
            }
            flatRowDivider()

            profileRow(label: NSLocalizedString("display_name", comment: "")) {
                Text(user.resolvedDisplayName)
                    .font(CTFont.regular(14))
                    .foregroundStyle(Color.CT.text)
            }
            flatRowDivider()

            profileRow(label: NSLocalizedString("user_id", comment: "")) {
                let uid = user.id
                let short = uid.count > 12 ? "\(uid.prefix(8))...\(uid.suffix(2))" : uid
                Text(short)
                    .font(CTFont.regular(13))
                    .foregroundStyle(Color.CT.textDim)
            }
        }
    }

    // MARK: - Actions section

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(NSLocalizedString("actions", comment: ""))
            flatRowDivider()

            if showMessageButton, let openChat = onOpenChat {
                actionRow(label: NSLocalizedString("synapses_open_chat", comment: ""), color: Color.CT.accent) {
                    openChat(); dismiss()
                }
                flatRowDivider()
            }

            if CallsFeature.isEnabled, case .idle = callManager.state {
                actionRow(label: NSLocalizedString("call_voice", comment: "Voice call"), color: Color.CT.accent) {
                    Task {
                        await callManager.startOutgoingCall(
                            to: user.id,
                            displayName: user.resolvedDisplayName,
                            hasVideo: false
                        )
                    }
                    dismiss()
                }
                flatRowDivider()

                if CallsFeature.isVideoEnabled {
                    actionRow(label: NSLocalizedString("call_video", comment: "Video call"), color: Color.CT.accent) {
                        Task {
                            await callManager.startOutgoingCall(
                                to: user.id,
                                displayName: user.resolvedDisplayName,
                                hasVideo: true
                            )
                        }
                        dismiss()
                    }
                    flatRowDivider()
                }
            } else if !CallsFeature.isEnabled {
                disabledRow(label: NSLocalizedString("call_voice", comment: "Voice call"))
                flatRowDivider()
            }

            if user.amISharingWith {
                actionRow(
                    label: NSLocalizedString("stop_sharing_profile", comment: ""),
                    color: Color.CT.text,
                    isLoading: isSharingInProgress
                ) { handleShareToggle(false) }
            } else {
                actionRow(
                    label: NSLocalizedString("share_my_profile", comment: ""),
                    color: Color.CT.accent,
                    isLoading: isSharingInProgress
                ) { handleShareToggle(true) }
            }

            if let sharedAt = user.sharedWithMeAt, user.isSharingWithMe {
                flatRowDivider()
                Text(String(format: NSLocalizedString("sharing_with_you", comment: ""), formatDate(sharedAt)))
                    .font(CTFont.regular(11))
                    .foregroundStyle(Color.CT.textDim)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
        }
    }

    // MARK: - Security / Crypto section

    private var securitySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(NSLocalizedString("security", comment: ""))
            flatRowDivider()

            profileRow(label: NSLocalizedString("session_crypto_suite", comment: "")) {
                HStack(spacing: 8) {
                    Text(hasSession ? "[ENC]" : "[---]")
                        .font(CTFont.regular(11))
                        .foregroundStyle(hasSession ? Color.CT.accent.opacity(0.8) : Color.CT.textDim)
                    if hasSession {
                        Text("[ OK ]")
                            .font(CTFont.regular(11))
                            .foregroundStyle(Color.CT.accent.opacity(0.6))
                    }
                }
            }
            flatRowDivider()

            profileRow(label: "") {
                Text(sessionSuiteLabel)
                    .font(CTFont.regular(13))
                    .foregroundStyle(hasSession ? Color.CT.text : Color.CT.textDim)
            }
            flatRowDivider()

            Button {
                showingSafetyNumbers = true
            } label: {
                profileRow(label: NSLocalizedString("safety_numbers", comment: "")) {
                    Text(CTSymbol.forward)
                        .font(CTFont.regular(13))
                        .foregroundStyle(Color.CT.textDim)
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Danger section

    private var dangerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(NSLocalizedString("danger_zone", comment: ""), color: Color.CT.danger)
            flatRowDivider()

            actionRow(
                label: NSLocalizedString(user.isBlocked ? "unblock_user" : "block_user", comment: ""),
                color: user.isBlocked ? Color.CT.text : Color.CT.danger
            ) { showingBlockConfirmation = true }
            flatRowDivider()

            actionRow(
                label: NSLocalizedString("reset_session", comment: ""),
                color: Color.CT.danger
            ) { showResetSessionConfirm = true }

            if let prune = onPrune {
                flatRowDivider()
                actionRow(label: NSLocalizedString("synapses_prune_action", comment: ""), color: Color.CT.danger) {
                    prune(); dismiss()
                }
            }
        }
    }

    // MARK: - Layout helpers

    private func flatDivider(thick: Bool = false) -> some View {
        Rectangle()
            .fill(thick ? Color.CT.noise : Color.CT.noise.opacity(0.5))
            .frame(height: 1)
    }

    private func flatRowDivider() -> some View {
        Rectangle()
            .fill(Color.CT.noise.opacity(0.35))
            .frame(height: 1)
            .padding(.horizontal, 20)
    }

    private func sectionHeader(_ title: String, color: Color = Color.CT.accent) -> some View {
        HStack(spacing: 6) {
            Text(">")
                .font(CTFont.bold(12))
                .foregroundStyle(color)
            Text(title.uppercased())
                .font(CTFont.bold(12))
                .foregroundStyle(color)
                .tracking(2)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func profileRow<V: View>(label: String, @ViewBuilder value: () -> V) -> some View {
        HStack {
            if !label.isEmpty {
                Text(label.lowercased())
                    .font(CTFont.regular(14))
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
                Text(label.lowercased())
                    .font(CTFont.regular(14))
                    .foregroundStyle(color)
                Spacer()
                if isLoading {
                    ProgressView().scaleEffect(0.75).tint(Color.CT.textDim)
                } else {
                    Text("[→]")
                        .font(CTFont.regular(13))
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

    private func disabledRow(label: String) -> some View {
        HStack {
            Text(label.lowercased())
                .font(CTFont.regular(14))
                .foregroundStyle(Color.CT.textDim)
            Spacer()
            Text("[soon]")
                .font(CTFont.regular(11))
                .foregroundStyle(Color.CT.textDim)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Helpers

    private func formatDate(_ date: Date) -> String {
        Self.profileDateFormatter.string(from: date)
    }

    private func refreshSessionSecurityState() {
        let sessionExists = SessionLifecycleController.shared.hasActiveSession(for: user.id)
        let suiteId = Int(KeychainManager.shared.loadSessionSuiteId(userId: user.id) ?? 0)
        hasSession = sessionExists
        sessionSuiteLabel = sessionExists && suiteId > 0
            ? cryptoSuiteName(suiteId: suiteId)
            : NSLocalizedString("session_crypto_no_session", comment: "")
    }

    private func handleShareToggle(_ share: Bool) {
        guard !isSharingInProgress else { return }
        if share {
            isSharingInProgress = true
            viewModel.shareProfile(with: user.id) { success, error in
                isSharingInProgress = false
                if success {
                    user.amISharingWith = true
                    viewContext.saveAndLog(category: "UserProfileView")
                    shareAlertMessage = NSLocalizedString("profile_shared_successfully", comment: "")
                } else {
                    shareAlertMessage = error ?? NSLocalizedString("failed_to_share_profile", comment: "")
                }
                showingShareAlert = true
            }
        } else {
            user.amISharingWith = false
            viewContext.saveAndLog(category: "UserProfileView")
            shareAlertMessage = NSLocalizedString("profile_sharing_stopped", comment: "")
            showingShareAlert = true
        }
    }

    private func handleBlockToggle() {
        user.isBlocked.toggle()
        viewContext.saveAndLog(category: "UserProfileView")
    }
}

// MARK: - Preview

#Preview {
    let container = PreviewHelpers.createPreviewContainer()
    let context = container.viewContext
    let user = PreviewHelpers.createSampleUser(context: context, id: "user1", username: "alice", displayName: "Alice Wonderland")
    user.isContact = true
    try? context.save()

    return UserProfileView(
        user: user,
        showMessageButton: true,
        onOpenChat: {},
        onPrune: {}
    )
    .environment(\.managedObjectContext, context)
}

#Preview {
    let container = PreviewHelpers.createPreviewContainer()
    let context = container.viewContext
    let user = PreviewHelpers.createSampleUser(context: context, id: "user1", username: "alice", displayName: "Alice")
    try? context.save()
    return UserProfileView(user: user)
        .environment(\.managedObjectContext, context)
}
