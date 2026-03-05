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
    
    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Profile Header
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            if let avatarData = user.avatarData,
                               let avatarImage = ImageHelper.imageFromData(avatarData) {
                                Image(uiImage: avatarImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 100, height: 100)
                                    .clipShape(AvatarStyle.squircle(AvatarStyle.accountSize))
                            } else {
                                AvatarStyle.squircle(AvatarStyle.accountSize)
                                    .fill(Color.blue.opacity(0.2))
                                    .frame(width: 100, height: 100)
                                    .overlay {
                                        Text(initials)
                                            .font(.system(size: 40, weight: .semibold))
                                            .foregroundColor(Color.blue)
                                    }
                            }
                            
                            Text(user.displayName)
                                .font(.title2)
                                .fontWeight(.semibold)
                            
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
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .padding(.vertical, 8)
                }
                
                // MARK: - Profile Sharing Status
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("profile_sharing_status")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 8)
                            Text(user.isSharingWithMe ? "sharing_with_you" : "not_sharing_with_you")
                                .font(.headline)
                                .padding(.horizontal, 8)
                        }
                        Spacer()
                        
                        if let sharedAt = user.sharedWithMeAt {
                            Text(formatDate(sharedAt))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("profile_sharing_info")
                } footer: {
                    Text("profile_sharing_info_footer")
                        .font(.caption)
                }
                
                // MARK: - Actions
                Section {
                    // Share profile button
                    if user.amISharingWith {
                        // Already sharing - show status and stop button
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(Color.AppStatus.success)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            
                            Button {
                                handleShareToggle(false)
                            } label: {
                                HStack {
                                    Image(systemName: "person.crop.circle.badge.minus")
                                    Text("stop_sharing_profile")
                                    Spacer()
                                }
                                .foregroundColor(.red)
                            }
                        }
                    } else {
                        // Not sharing - show share button
                        Button {
                            handleShareToggle(true)
                        } label: {
                            HStack {
                                Text("share_my_profile")
                                    .padding(.horizontal, 8)
                            }
                        }
                    }
                    
                    // Block user button
                    Button(role: .destructive) {
                        showingBlockConfirmation = true
                    } label: {
                        HStack {
                            Text(user.isBlocked ? "unblock_user" : "block_user").padding(.horizontal, 8)
                        }
                    }
                    
                    // Reset encrypted session
                    Button(role: .destructive) {
                        showResetSessionConfirm = true
                    } label: {
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("reset_session")
                                .padding(.horizontal, 8)
                        }
                    }
                } header: {
                    Text("actions")
                } footer: {
                    if user.isBlocked {
                        Text("user_is_blocked_footer")
                            .font(.caption)
                            .foregroundColor(.red)
                    } else if !user.amISharingWith {
                        Text("share_profile_explanation")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                viewModel.setContext(viewContext)
            }
            .alert("block_user_confirmation", isPresented: $showingBlockConfirmation) {
                Button("cancel", role: .cancel) { }
                Button(user.isBlocked ? "unblock" : "block", role: user.isBlocked ? .none : .destructive) {
                    handleBlockToggle()
                }
            } message: {
                Text(user.isBlocked ? "unblock_user_confirmation_message" : "block_user_confirmation_message")
            }
            .alert("share_my_data_alert", isPresented: $showingShareAlert) {
                Button("ok") { }
            } message: {
                Text(shareAlertMessage)
            }
            .confirmationDialog(
                "reset_session_title",
                isPresented: $showResetSessionConfirm,
                titleVisibility: .visible
            ) {
                Button("reset_session", role: .destructive) {
                    Task {
                        do {
                            let chatsVM = ChatsViewModel()
                            try await chatsVM.sendEndSession(to: user.id, reason: "user_requested")
                            Log.info("✅ Session reset from profile for \(user.id.prefix(8))…", category: "UserProfileView")
                        } catch {
                            Log.error("❌ Failed to reset session: \(error)", category: "UserProfileView")
                        }
                    }
                }
                Button("cancel", role: .cancel) {}
            } message: {
                Text("reset_session_message")
            }
        }
    }
    
    private var initials: String {
        let displayName = user.displayName
        let components = displayName.split(separator: " ")
        if components.count >= 2 {
            return String(components[0].prefix(1) + components[1].prefix(1)).uppercased()
        }
        return String(displayName.prefix(2)).uppercased()
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    private func handleShareToggle(_ share: Bool) {
        
        if share {
            // Share profile with user
            viewModel.shareProfile(with: user.id) { success, error in
                if success {
                    user.amISharingWith = true
                    try? viewContext.save()
                    shareAlertMessage = NSLocalizedString("profile_shared_successfully", comment: "")
                    showingShareAlert = true
                } else {
                    shareAlertMessage = error ?? NSLocalizedString("failed_to_share_profile", comment: "")
                    showingShareAlert = true
                }
            }
        } else {
            // Stop sharing
            user.amISharingWith = false
            try? viewContext.save()
            shareAlertMessage = NSLocalizedString("profile_sharing_stopped", comment: "")
            showingShareAlert = true
        }
    }
    
    private func handleBlockToggle() {
        user.isBlocked.toggle()
        
        // TODO: Send block/unblock message to server when server support is implemented
        // For now, just update local state
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
