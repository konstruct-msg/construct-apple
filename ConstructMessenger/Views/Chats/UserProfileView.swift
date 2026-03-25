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
    @State private var showingBlockConfirmation = false
    @State private var showResetSessionConfirm = false
    @State private var showingShareAlert = false
    @State private var shareAlertMessage = ""
    @State private var isSharingInProgress = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.Construct.bg.ignoresSafeArea()

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
            .toolbarBackground(Color.Construct.bg2, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(ConstructFont.display(16, weight: .medium))
                        .foregroundStyle(Color.Construct.accent)
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
        VStack(spacing: 12) {
            ZStack {
                if let data = user.avatarData, let img = PlatformImage(data: data) {
                    Image(platformImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Circle().fill(accentColor.opacity(0.18))
                    Text(initials)
                        .font(ConstructFont.mono(32, weight: .semibold))
                        .foregroundStyle(accentColor)
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(Circle())
            .overlay(
                Circle().strokeBorder(
                    user.isBlocked ? Color.red.opacity(0.5) : Color.Construct.dim,
                    lineWidth: 2
                )
            )

            VStack(spacing: 4) {
                Text(user.resolvedDisplayName)
                    .font(ConstructFont.display(22, weight: .semibold))
                    .foregroundStyle(Color.Construct.textBright)

                if !user.username.isEmpty {
                    Text("@\(user.username)")
                        .font(ConstructFont.mono(13))
                        .foregroundStyle(Color.Construct.textDim)
                }

                if user.isBlocked {
                    Label("Blocked", systemImage: "slash.circle")
                        .font(ConstructFont.mono(11, weight: .semibold))
                        .foregroundStyle(Color.red)
                        .padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(Color.Construct.bg2)
    }

    // MARK: - Actions list

    private var actionsList: some View {
        VStack(spacing: 9) {
            if showMessageButton, let openChat = onOpenChat {
                ConstructActionRow(icon: "message.fill", title: LocalizedStringKey("synaps_open_chat"), role: .primary) {
                    openChat()
                    dismiss()
                }
            }

            ConstructActionRow(icon: "phone.fill", title: "Voice call", role: .disabled) {}

            if user.amISharingWith {
                ConstructActionRow(icon: "person.crop.circle.badge.minus", title: LocalizedStringKey("stop_sharing_profile"), role: .secondary, isLoading: isSharingInProgress) {
                    handleShareToggle(false)
                }
            } else {
                ConstructActionRow(icon: "person.crop.circle.badge.checkmark", title: LocalizedStringKey("share_my_profile"), role: .accent, isLoading: isSharingInProgress) {
                    handleShareToggle(true)
                }
            }

            Spacer()

            ConstructActionRow(
                icon: user.isBlocked ? "checkmark.circle" : "slash.circle",
                title: LocalizedStringKey(user.isBlocked ? "unblock_user" : "block_user"),
                role: .secondary
            ) {
                showingBlockConfirmation = true
            }

            ConstructActionRow(icon: "arrow.counterclockwise", title: LocalizedStringKey("reset_session"), role: .destructive) {
                showResetSessionConfirm = true
            }

            if let prune = onPrune {
                ConstructActionRow(icon: "scissors", title: LocalizedStringKey("synaps_prune_action"), role: .destructive) {
                    prune()
                    dismiss()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
    }

    // MARK: - Crypto section

    private var cryptoSection: some View {
        let hasSession = CryptoManager.shared.hasSession(for: user.id)
        let suiteId = UserDefaults.standard.integer(forKey: "construct.session.suite.\(user.id)")
        let suiteLabel = hasSession && suiteId > 0
            ? cryptoSuiteName(suiteId: suiteId)
            : NSLocalizedString("session_crypto_no_session", comment: "")

        return VStack(spacing: 0) {
            Divider()
                .background(Color.Construct.dim)
                .padding(.horizontal, 16)

            HStack(spacing: 10) {
                Image(systemName: hasSession ? "lock.fill" : "lock.open")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(hasSession ? Color.Construct.accent.opacity(0.8) : Color.Construct.textDim)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey("session_crypto_suite"))
                        .font(ConstructFont.mono(11, weight: .medium))
                        .foregroundStyle(Color.Construct.textDim)
                    Text(suiteLabel)
                        .font(ConstructFont.mono(13, weight: .semibold))
                        .foregroundStyle(hasSession ? Color.Construct.textBright : Color.Construct.textDim)
                }

                Spacer()

                if hasSession {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.Construct.accent.opacity(0.7))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .padding(.top, 12)
    }

    // MARK: - Sharing status

    private var sharingStatus: some View {
        Group {
            if let sharedAt = user.sharedWithMeAt, user.isSharingWithMe {
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        String(format: NSLocalizedString("sharing_with_you", comment: ""), formatDate(sharedAt)),
                        systemImage: "checkmark.shield"
                    )
                    .font(ConstructFont.mono(11))
                    .foregroundStyle(Color.Construct.textDim)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 20)
            }
        }
    }

    // MARK: - Helpers

    private var accentColor: Color { .hexagonAccent(for: user.id) }

    private var initials: String {
        let words = user.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        switch words.count {
        case 0:  return "?"
        case 1:  return String(words[0].prefix(2)).uppercased()
        default: return (String(words[0].prefix(1)) + String(words[1].prefix(1))).uppercased()
        }
    }

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
