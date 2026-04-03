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

    var body: some View {
        NavigationStack {
            ZStack {
                Color.CT.bg.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        avatarHeader
                        actionsList
                        cryptoSection
                        sharingStatus
                    }
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.CT.bgMsg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("[ done ]") { dismiss() }
                        .font(CTFont.regular(13))
                        .foregroundStyle(Color.CT.textDim)
                }
            }
            .onAppear { viewModel.setContext(viewContext) }
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
                        try? await SessionCoordinator().sendEndSession(to: user.id, reason: "user_requested")
                    }
                }
                Button(LocalizedStringKey("cancel"), role: .cancel) {}
            } message: {
                Text(LocalizedStringKey("reset_session_message"))
            }
        }
    }

    // MARK: - Avatar header

    private var avatarHeader: some View {
        let avatarImage: PlatformImage? = user.avatarData.flatMap { PlatformImage(data: $0) }
        return VStack(spacing: 12) {
            HexagonAvatarView(
                userId: user.id,
                displayName: user.resolvedDisplayName,
                image: avatarImage,
                size: 96,
                isActive: false
            )

            VStack(spacing: 4) {
                Text(user.resolvedDisplayName)
                    .font(CTFont.bold(22))
                    .foregroundStyle(Color.CT.text)

                if !user.username.isEmpty {
                    Text("@\(user.username)")
                        .font(CTFont.regular(13))
                        .foregroundStyle(Color.CT.textDim)
                }

                if user.isBlocked {
                    Text("[ BLOCKED ]")
                        .font(CTFont.bold(10))
                        .foregroundStyle(Color.CT.danger)
                        .padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(Color.CT.bgMsg)
    }

    // MARK: - Actions list

    private var actionsList: some View {
        VStack(spacing: 20) {
            // Primary actions
            ConstructSection(header: nil) {
                if showMessageButton, let openChat = onOpenChat {
                    profileActionRow(label: LocalizedStringKey("synaps_open_chat"), color: Color.CT.accent) {
                        openChat()
                        dismiss()
                    }
                    ConstructRowDivider(indent: 16)
                }

                if CallsFeature.isEnabled, case .idle = callManager.state {
                    profileActionRow(label: "Voice Call", color: Color.CT.accent) {
                        Task {
                            await callManager.startOutgoingCall(
                                to: user.id,
                                displayName: user.resolvedDisplayName,
                                hasVideo: false
                            )
                        }
                        dismiss()
                    }
                    ConstructRowDivider(indent: 16)
                } else if !CallsFeature.isEnabled {
                    profileActionRowDisabled(label: "Voice Call")
                    ConstructRowDivider(indent: 16)
                }

                if user.amISharingWith {
                    profileActionRow(label: LocalizedStringKey("stop_sharing_profile"), color: Color.CT.text, isLoading: isSharingInProgress) {
                        handleShareToggle(false)
                    }
                } else {
                    profileActionRow(label: LocalizedStringKey("share_my_profile"), color: Color.CT.accent, isLoading: isSharingInProgress) {
                        handleShareToggle(true)
                    }
                }
            }

            // Block
            ConstructSection(header: nil) {
                profileActionRow(
                    label: LocalizedStringKey(user.isBlocked ? "unblock_user" : "block_user"),
                    color: Color.CT.text
                ) {
                    showingBlockConfirmation = true
                }
            }

            // Destructive
            ConstructSection(header: nil) {
                profileActionRow(label: LocalizedStringKey("reset_session"), color: Color.CT.danger) {
                    showResetSessionConfirm = true
                }
                if let prune = onPrune {
                    ConstructRowDivider(indent: 16)
                    profileActionRow(label: LocalizedStringKey("synaps_prune_action"), color: Color.CT.danger) {
                        prune()
                        dismiss()
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
    }

    // MARK: - Row helpers

    @ViewBuilder
    private func profileActionRow(label: LocalizedStringKey, color: Color, isLoading: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: { guard !isLoading else { return }; action() }) {
            HStack {
                Text(label)
                    .font(CTFont.bold(15))
                    .foregroundStyle(color)
                Spacer()
                if isLoading {
                    ProgressView().scaleEffect(0.75).tint(Color.CT.textDim)
                } else {
                    Text(">")
                        .font(CTFont.regular(13))
                        .foregroundStyle(Color.CT.textDim)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }

    @ViewBuilder
    private func profileActionRowDisabled(label: String) -> some View {
        HStack {
            Text(label)
                .font(CTFont.bold(15))
                .foregroundStyle(Color.CT.textDim)
            Spacer()
            Text("soon")
                .font(CTFont.regular(10))
                .foregroundStyle(Color.CT.textDim)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .overlay(Rectangle().strokeBorder(Color.CT.noise, lineWidth: 1))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Crypto section

    private var cryptoSection: some View {
        let hasSession = CryptoManager.shared.hasSession(for: user.id)
        let suiteId = UserDefaults.standard.integer(forKey: "construct.session.suite.\(user.id)")
        let suiteLabel = hasSession && suiteId > 0
            ? cryptoSuiteName(suiteId: suiteId)
            : NSLocalizedString("session_crypto_no_session", comment: "")

        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(hasSession ? "[ENC]" : "[---]")
                    .font(CTFont.regular(10))
                    .foregroundStyle(hasSession ? Color.CT.accent.opacity(0.8) : Color.CT.textDim)
                    .frame(width: 36, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey("session_crypto_suite"))
                        .font(CTFont.medium(11))
                        .foregroundStyle(Color.CT.textDim)
                    Text(suiteLabel)
                        .font(CTFont.bold(13))
                        .foregroundStyle(hasSession ? Color.CT.text : Color.CT.textDim)
                }

                Spacer()

                if hasSession {
                    Text("[ OK ]")
                        .font(CTFont.regular(10))
                        .foregroundStyle(Color.CT.accent.opacity(0.7))
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 14)
        }
        .padding(.top, 4)
    }

    // MARK: - Sharing status

    private var sharingStatus: some View {
        Group {
            if let sharedAt = user.sharedWithMeAt, user.isSharingWithMe {
                Text(String(format: NSLocalizedString("sharing_with_you", comment: ""), formatDate(sharedAt)))
                    .font(CTFont.regular(11))
                    .foregroundStyle(Color.CT.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.top, 8)
            }
        }
    }

    // MARK: - Helpers

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }

    private func handleShareToggle(_ share: Bool) {
        guard !isSharingInProgress else { return }
        if share {
            isSharingInProgress = true
            viewModel.shareProfile(with: user.id) { success, error in
                isSharingInProgress = false
                if success {
                    user.amISharingWith = true
                    try? viewContext.save()
                    shareAlertMessage = NSLocalizedString("profile_shared_successfully", comment: "")
                } else {
                    shareAlertMessage = error ?? NSLocalizedString("failed_to_share_profile", comment: "")
                }
                showingShareAlert = true
            }
        } else {
            user.amISharingWith = false
            try? viewContext.save()
            shareAlertMessage = NSLocalizedString("profile_sharing_stopped", comment: "")
            showingShareAlert = true
        }
    }

    private func handleBlockToggle() {
        user.isBlocked.toggle()
        try? viewContext.save()
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
