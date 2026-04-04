//
//  AccountSettingsView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 30.12.2025.
//

import SwiftUI
import CoreData
import PhotosUI

struct AccountSettingsView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(AuthViewModel.self) private var authViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = SettingsViewModel()

    @State private var showingImagePicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showingAvatarViewer = false
    @State private var showingDeleteConfirmation = false
    @State private var showingExportAlert = false
    @State private var imageToCrop: UIImage?
    @State private var showingCropView = false
    @State private var isEditingDisplayName = false
    @State private var isEditingUsername = false

    @State private var originalUsername: String = ""

    var body: some View {
        VStack(spacing: 0) {
            CTNavBar(
                title: NSLocalizedString("account", comment: ""),
                showBack: true,
                backAction: { dismiss() }
            )
            flatDivider(thick: true)

            ScrollView {
                VStack(spacing: 0) {
                    avatarHeader
                    flatDivider(thick: true)
                    identitySection
                    flatDivider(thick: true)
                    accountSection
                    flatDivider(thick: true)
                    dangerSection
                    flatDivider(thick: true)

                    Text(NSLocalizedString("changes_encrypted_footer", comment: ""))
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.accent.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                }
            }
        }
        .background(Color.CT.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            viewModel.setContext(viewContext)
            viewModel.loadUserInfo(from: authViewModel)
            originalUsername = viewModel.username
        }
        .onChange(of: viewModel.usernameSaved) { _, saved in
            if saved { originalUsername = viewModel.username }
        }
        .alert(LocalizedStringKey("export_my_data"), isPresented: $showingExportAlert) {
            Button(LocalizedStringKey("ok"), role: .cancel) { }
        } message: {
            Text(LocalizedStringKey("export_coming_soon_message"))
        }
        .sheet(isPresented: $showingDeleteConfirmation) {
            DeleteAccountConfirmationView(onDelete: { authViewModel.deleteAccount() },
                                         onCancel: { showingDeleteConfirmation = false })
            .environment(authViewModel)
        }
        .sheet(isPresented: $showingAvatarViewer) {
            AvatarViewerSheet(image: viewModel.profileImage, onChangeAvatar: {
                showingAvatarViewer = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showingImagePicker = true }
            })
        }
        .photosPicker(isPresented: $showingImagePicker, selection: $selectedPhotoItem, matching: .images)
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    await MainActor.run { imageToCrop = image; showingCropView = true }
                }
                selectedPhotoItem = nil
            }
        }
        .sheet(isPresented: $showingCropView) {
            if let img = imageToCrop {
                ImageCropView(
                    image: img,
                    onConfirm: { cropped in
                        showingCropView = false; imageToCrop = nil
                        viewModel.saveAvatar(cropped, authViewModel: authViewModel)
                    },
                    onCancel: { showingCropView = false; imageToCrop = nil }
                )
            }
        }
    }

    // MARK: - Avatar Header

    private var avatarHeader: some View {
        VStack(spacing: 14) {
            HexagonAvatarView(
                userId: viewModel.userId,
                displayName: viewModel.displayName,
                image: viewModel.profileImage,
                size: AvatarStyle.accountSize,
                isActive: false
            )
            .onTapGesture {
                if viewModel.profileImage != nil { showingAvatarViewer = true }
                else { showingImagePicker = true }
            }

            Button {
                showingImagePicker = true
            } label: {
                Text("[\(NSLocalizedString("change_photo", comment: ""))]")
                    .font(CTFont.regular(13))
                    .foregroundStyle(Color.CT.accent)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    // MARK: - Identity Section

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(NSLocalizedString("identity_section", comment: ""))
            flatRowDivider()

            // username
            profileRow(label: NSLocalizedString("username", comment: "")) {
                Text("<@\(viewModel.username.isEmpty ? "—" : viewModel.username)>")
                    .font(CTFont.regular(14))
                    .foregroundStyle(Color.CT.textDim)
            }
            flatRowDivider()

            // display name
            profileEditRow(
                label: NSLocalizedString("display_name", comment: ""),
                isEditing: $isEditingDisplayName,
                value: $viewModel.displayName,
                onCommit: { viewModel.saveDisplayName(viewModel.displayName, authViewModel: authViewModel) }
            )
            flatRowDivider()

            // status — placeholder, not yet implemented
            profileRow(label: NSLocalizedString("status", comment: "")) {
                HStack(spacing: 8) {
                    Text("[[ONLINE]]")
                        .font(CTFont.regular(14))
                        .foregroundStyle(Color.CT.accent)
                    Text("[→]")
                        .font(CTFont.regular(13))
                        .foregroundStyle(Color.CT.accent.opacity(0.6))
                }
            }
            flatRowDivider()

            // bio — placeholder, not yet implemented
            profileRow(label: NSLocalizedString("bio", comment: "")) {
                Text("[\(NSLocalizedString("add_action", comment: "")) [→]]")
                    .font(CTFont.regular(13))
                    .foregroundStyle(Color.CT.accent.opacity(0.6))
            }
        }
    }

    // MARK: - Account Section

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(NSLocalizedString("account_section", comment: ""))
            flatRowDivider()

            // user ID
            profileRow(label: NSLocalizedString("user_id", comment: "")) {
                let uid = viewModel.userId
                let short = uid.count > 12
                    ? "\(uid.prefix(8))...\(uid.suffix(2))"
                    : uid
                Text(short)
                    .font(CTFont.regular(14))
                    .foregroundStyle(Color.CT.textDim)
            }
            flatRowDivider()

            // linked devices
            NavigationLink(destination: DevicesView()) {
                HStack {
                    Text(NSLocalizedString("linked_devices", comment: "").lowercased())
                        .font(CTFont.regular(14))
                        .foregroundStyle(Color.CT.textDim)
                    Spacer()
                    Text("[\(NSLocalizedString("manage_action", comment: "")) [→]]")
                        .font(CTFont.regular(13))
                        .foregroundStyle(Color.CT.accent)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Danger Zone

    private var dangerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(NSLocalizedString("danger_zone", comment: ""), color: Color.CT.danger)
            flatRowDivider()

            Button {
                showingDeleteConfirmation = true
            } label: {
                HStack {
                    Text(NSLocalizedString("delete_account_row", comment: "").lowercased())
                        .font(CTFont.regular(14))
                        .foregroundStyle(Color.CT.danger)
                    Spacer()
                    Text("[\(NSLocalizedString("delete_action", comment: "")) →]")
                        .font(CTFont.regular(13))
                        .foregroundStyle(Color.CT.danger.opacity(0.7))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Layout Helpers

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
            Text(label.lowercased())
                .font(CTFont.regular(14))
                .foregroundStyle(Color.CT.textDim)
            Spacer()
            value()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func profileEditRow(
        label: String,
        isEditing: Binding<Bool>,
        value: Binding<String>,
        onCommit: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(label.lowercased())
                .font(CTFont.regular(14))
                .foregroundStyle(Color.CT.textDim)
            Spacer()
            if isEditing.wrappedValue {
                TextField("", text: value)
                    .font(CTFont.regular(14))
                    .foregroundStyle(Color.CT.text)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .onSubmit {
                        onCommit()
                        isEditing.wrappedValue = false
                    }
                    .frame(maxWidth: 180)
                Button {
                    onCommit()
                    isEditing.wrappedValue = false
                } label: {
                    Text("[→]")
                        .font(CTFont.regular(13))
                        .foregroundStyle(Color.CT.accent)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    isEditing.wrappedValue = true
                } label: {
                    HStack(spacing: 8) {
                        Text(value.wrappedValue.isEmpty ? "—" : value.wrappedValue)
                            .font(CTFont.regular(14))
                            .foregroundStyle(Color.CT.text)
                        Text("[→]")
                            .font(CTFont.regular(13))
                            .foregroundStyle(Color.CT.accent)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}


// MARK: - Delete Account Confirmation View
struct DeleteAccountConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthViewModel.self) private var authViewModel

    let onDelete: () -> Void
    let onCancel: () -> Void

    @State private var countdown = 7
    @State private var showLocalDeleteConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            // Drag indicator
            Capsule()
                .fill(Color.CT.noise)
                .frame(width: 36, height: 4)
                .padding(.top, 12)
                .padding(.bottom, 24)

            Spacer()

            Text(LocalizedStringKey("delete_my_account"))
                .font(CTFont.bold(20))
                .foregroundStyle(Color.CT.text)
                .padding(.bottom, 8)

            Text(LocalizedStringKey("delete_account_confirmation_message"))
                .font(CTFont.regular(14))
                .foregroundStyle(Color.CT.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 32)

            // Retro digital countdown
            if countdown > 0 && !authViewModel.isLoading {
                CTDigitalCountdown(value: countdown)
                    .padding(.bottom, 28)
            }

            // Local-delete fallback — shown after a server-side deletion failure
            if authViewModel.deleteAccountFailed {
                Button {
                    showLocalDeleteConfirm = true
                } label: {
                    Text(LocalizedStringKey("delete_account_local_only"))
                        .font(CTFont.regular(12))
                        .underline()
                        .foregroundStyle(Color.CT.danger.opacity(0.75))
                }
                .padding(.bottom, 16)
            }

            Spacer()

            // Delete button (full-width, appears after countdown)
            VStack(spacing: 12) {
                if authViewModel.isLoading {
                    ProgressView()
                        .tint(Color.CT.danger)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                } else {
                    Button {
                        onDelete()
                    } label: {
                        Text(LocalizedStringKey("delete_account"))
                            .font(CTFont.bold(16))
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(
                                Rectangle()
                                    .fill(countdown > 0 ? Color.CT.danger.opacity(0.08) : Color.CT.danger.opacity(0.15))
                                    .overlay(
                                        Rectangle()
                                            .strokeBorder(countdown > 0 ? Color.CT.danger.opacity(0.2) : Color.CT.danger.opacity(0.5), lineWidth: 1)
                                    )
                            )
                            .foregroundStyle(countdown > 0 ? Color.CT.danger.opacity(0.4) : Color.CT.danger)
                    }
                    .disabled(countdown > 0)
                    .animation(.easeInOut(duration: 0.25), value: countdown)
                }

                Button {
                    onCancel()
                    dismiss()
                } label: {
                    Text(LocalizedStringKey("cancel"))
                        .font(CTFont.regular(15))
                        .foregroundStyle(Color.CT.textDim)
                }
                .disabled(authViewModel.isLoading)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 36)
        }
        .background(Color.CT.bg)
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
        .alert("delete_account_local_only_title", isPresented: $showLocalDeleteConfirm) {
            Button("delete_account_local_only_confirm", role: .destructive) {
                authViewModel.deleteAccountLocally()
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("delete_account_local_only_warning")
        }
        .task {
            // Count down from 7 to 0 using structured concurrency — avoids RunLoop blocking on macOS.
            while countdown > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard countdown > 0 else { break }
                countdown -= 1
            }
        }
        .onChange(of: authViewModel.isLoading) { _, loading in
            // Reset failed state when a new deletion attempt starts
            if loading { authViewModel.deleteAccountFailed = false }
        }
        // On macOS Catalyst, sheets are child windows and don't auto-close
        // when parent view changes — explicitly dismiss when account is deleted.
        .onChange(of: authViewModel.isAuthenticated) { _, isAuthenticated in
            if !isAuthenticated { dismiss() }
        }
    }
}

// MARK: - Avatar Viewer Sheet
struct AvatarViewerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let image: UIImage?
    let onChangeAvatar: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .ignoresSafeArea(edges: .bottom)
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("close") { dismiss() }
                        .foregroundColor(.white)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("change_avatar") { onChangeAvatar() }
                        .foregroundColor(.white)
                }
            }
            #if os(iOS)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            #endif
        }
    }
}


#if DEBUG
#Preview {
    let container = PreviewHelpers.createPreviewContainer()
    let context = container.viewContext

    // Create sample user
    let user = User(context: context)
    user.id = "user123"
    user.username = "john_doe"
    user.displayName = "John Doe"

    try? context.save()

    let authViewModel = AuthViewModel(context: context)
    authViewModel.configureMockAuth()

    return NavigationStack {
        AccountSettingsView()
            .environment(\.managedObjectContext, context)
            .environment(authViewModel)
    }
    .preferredColorScheme(.dark)
}
#endif
