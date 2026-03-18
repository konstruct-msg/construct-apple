//
//  UserProfileView.swift
//  Construct Messenger
//
//  Profile view for viewing and managing user profile data sharing
//

import SwiftUI
import CoreData

struct UserProfileView: View {
    @ObservedObject var user: User
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
            ScrollView {
                VStack(spacing: 0) {
                    avatarHeader
                    Divider()
                    sharingStatusSection
                    Divider()
                    actionsSection
                }
            }
            .background(Color.secondary.opacity(0.08))
            .navigationTitle(LocalizedStringKey("profile"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button(LocalizedStringKey("done")) { dismiss() }
                }
            }
            .onAppear { viewModel.setContext(viewContext) }
            .alert(LocalizedStringKey("block_user_confirmation"), isPresented: $showingBlockConfirmation) {
                Button(LocalizedStringKey("cancel"), role: .cancel) { }
                Button(user.isBlocked ? LocalizedStringKey("unblock") : LocalizedStringKey("block"),
                       role: user.isBlocked ? .none : .destructive) { handleBlockToggle() }
            } message: {
                Text(LocalizedStringKey(user.isBlocked ? "unblock_user_confirmation_message" : "block_user_confirmation_message"))
            }
            .alert(LocalizedStringKey("share_my_data_alert"), isPresented: $showingShareAlert) {
                Button(LocalizedStringKey("ok")) { }
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
                            try await SessionCoordinator().sendEndSession(to: user.id, reason: "user_requested")
                        } catch {
                            Log.error("❌ Failed to reset session: \(error)", category: "UserProfileView")
                        }
                    }
                }
                Button(LocalizedStringKey("cancel"), role: .cancel) {}
            } message: {
                Text(LocalizedStringKey("reset_session_message"))
            }
        }
    }

    // MARK: - Avatar Header

    private var avatarHeader: some View {
        VStack(spacing: 10) {
            if let avatarData = user.avatarData,
               let avatarImage = ImageHelper.imageFromData(avatarData) {
                #if canImport(UIKit)
                Image(uiImage: avatarImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 88, height: 88)
                    .clipShape(AvatarStyle.squircle(AvatarStyle.accountSize))
                #else
                Image(nsImage: avatarImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 88, height: 88)
                    .clipShape(AvatarStyle.squircle(AvatarStyle.accountSize))
                #endif
            } else {
                AvatarStyle.squircle(AvatarStyle.accountSize)
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 88, height: 88)
                    .overlay {
                        Text(initials)
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundColor(.blue)
                    }
            }

            Text(user.displayName)
                .font(.title3.weight(.semibold))

            if !user.username.isEmpty {
                Text("@\(user.username)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                Text(DisplayNameGenerator.generate(from: user.id))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(Color.secondary.opacity(0.12))
    }

    // MARK: - Sharing Status

    private var sharingStatusSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(LocalizedStringKey("profile_sharing_info"))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(LocalizedStringKey("profile_sharing_status"))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    if let sharedAt = user.sharedWithMeAt {
                        Text(formatDate(sharedAt))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Text(LocalizedStringKey(user.isSharingWithMe ? "sharing_with_you" : "not_sharing_with_you"))
                    .font(.body)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.secondary.opacity(0.12))

            sectionFooter(LocalizedStringKey("profile_sharing_info_footer"))
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(LocalizedStringKey("actions"))
            VStack(spacing: 0) {
                // Share / stop sharing
                if user.amISharingWith {
                    actionRow {
                        HStack {
                            Text(LocalizedStringKey("stop_sharing_profile"))
                                .foregroundColor(.red)
                            Spacer()
                            if isSharingInProgress {
                                ProgressView().scaleEffect(0.8)
                            }
                        }
                    } action: { handleShareToggle(false) }
                } else {
                    actionRow {
                        HStack {
                            Text(LocalizedStringKey("share_my_profile"))
                            Spacer()
                            if isSharingInProgress {
                                ProgressView().scaleEffect(0.8)
                            }
                        }
                    } action: { handleShareToggle(true) }
                }

                Divider().padding(.leading, 16)

                // Block / unblock
                actionRow {
                    Text(LocalizedStringKey(user.isBlocked ? "unblock_user" : "block_user"))
                        .foregroundColor(user.isBlocked ? .primary : .red)
                } action: { showingBlockConfirmation = true }

                Divider().padding(.leading, 16)

                // Reset session
                actionRow {
                    Text(LocalizedStringKey("reset_session"))
                        .foregroundColor(.red)
                } action: { showResetSessionConfirm = true }
            }
            .background(Color.secondary.opacity(0.12))

            if user.isBlocked {
                sectionFooter(LocalizedStringKey("user_is_blocked_footer"), color: .red)
            } else if !user.amISharingWith {
                sectionFooter(LocalizedStringKey("share_profile_explanation"))
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func actionRow<Label: View>(@ViewBuilder label: () -> Label, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSharingInProgress)
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.footnote)
            .foregroundColor(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 6)
    }

    private func sectionFooter(_ text: LocalizedStringKey, color: Color = .secondary) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundColor(color)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 8)
    }

    private var initials: String {
        let components = user.displayName.split(separator: " ")
        if components.count >= 2 {
            return String(components[0].prefix(1) + components[1].prefix(1)).uppercased()
        }
        return String(user.displayName.prefix(2)).uppercased()
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
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

#Preview {
    let container = PreviewHelpers.createPreviewContainer()
    let context = container.viewContext
    let user = PreviewHelpers.createSampleUser(context: context, id: "user1", username: "alice", displayName: "Alice")
    try? context.save()
    return UserProfileView(user: user)
        .environment(\.managedObjectContext, context)
}
