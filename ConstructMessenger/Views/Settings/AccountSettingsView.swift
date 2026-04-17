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
    @Environment(AccountRecoveryViewModel.self) private var recoveryVM
    @Environment(SocialRecoveryService.self) private var socialRecoveryService
    @Environment(SettingsViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showingImagePicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showingAvatarViewer = false
    @State private var showingDeleteConfirmation = false
    @State private var showingExportBackup = false
    @State private var showingImportBackup = false
    @State private var imageToCrop: UIImage?
    @State private var showingCropView = false
    @State private var isEditingDisplayName = false
    @State private var isEditingUsername = false

    @State private var originalUsername: String = ""

    // Logout flow
    @State private var showingLogoutConfirm = false
    @State private var showingLogoutAllConfirm = false
    @State private var showingNoBackupWarning = false
    @State private var showingRecoverySetup = false
    @State private var showingSocialRecoverySetup = false
    @State private var pendingLogoutAll = false  // which logout action was requested before backup check

    var body: some View {
        @Bindable var viewModel = viewModel
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
                    backupSection
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
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .onAppear {
            viewModel.setContext(viewContext)
            viewModel.loadUserInfo(from: authViewModel)
            originalUsername = viewModel.username
        }
        .onChange(of: viewModel.usernameSaved) { _, saved in
            if saved { originalUsername = viewModel.username }
        }
        .sheet(isPresented: $showingExportBackup) {
            ExportBackupView()
                .environment(\.managedObjectContext, viewContext)
        }
        .sheet(isPresented: $showingImportBackup) {
            ImportBackupView()
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
        // Sign out this device
        .alert(LocalizedStringKey("logout_confirm_title"), isPresented: $showingLogoutConfirm) {
            Button(LocalizedStringKey("logout_confirm_action"), role: .destructive) {
                authViewModel.logout()
            }
            Button(LocalizedStringKey("cancel"), role: .cancel) { }
        } message: {
            Text(LocalizedStringKey("logout_confirm_message"))
        }
        // Sign out all devices
        .alert(LocalizedStringKey("logout_all_confirm_title"), isPresented: $showingLogoutAllConfirm) {
            Button(LocalizedStringKey("logout_all_confirm_action"), role: .destructive) {
                authViewModel.logoutAllDevices()
            }
            Button(LocalizedStringKey("cancel"), role: .cancel) { }
        } message: {
            Text(LocalizedStringKey("logout_all_confirm_message"))
        }
        // No backup warning
        .alert(LocalizedStringKey("logout_no_backup_title"), isPresented: $showingNoBackupWarning) {
            Button(LocalizedStringKey("logout_no_backup_setup_action")) {
                showingRecoverySetup = true
            }
            Button(LocalizedStringKey("logout_no_backup_proceed_action"), role: .destructive) {
                if pendingLogoutAll { authViewModel.logoutAllDevices() }
                else { authViewModel.logout() }
            }
            Button(LocalizedStringKey("cancel"), role: .cancel) { }
        } message: {
            Text(LocalizedStringKey("logout_no_backup_message"))
        }
        .sheet(isPresented: $showingRecoverySetup) {
            RecoverySetupView()
                .environment(recoveryVM)
                .environment(authViewModel)
        }
        .sheet(isPresented: $showingSocialRecoverySetup) {
            SocialRecoverySetupView()
                .environment(socialRecoveryService)
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
        @Bindable var viewModel = viewModel
        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader(NSLocalizedString("identity_section", comment: ""))
            flatRowDivider()

            // username — editable, server-validated
            profileEditRow(
                label: NSLocalizedString("username", comment: ""),
                isEditing: $isEditingUsername,
                value: $viewModel.username,
                hint: NSLocalizedString("username_hint", comment: ""),
                maxLength: MessageSizeLimits.maxUsernameCharacters,
                isSaving: viewModel.isSavingUsername,
                errorMessage: viewModel.usernameSaveError,
                onCommit: {
                    Task { await viewModel.saveUsername(viewModel.username, authViewModel: authViewModel) }
                }
            )
            flatRowDivider()
            HStack(spacing: 8) {
                Text(viewModel.isDiscoverable
                    ? NSLocalizedString("searchable_indicator", comment: "")
                    : NSLocalizedString("searchable_indicator_off", comment: ""))
                    .font(CTFont.regular(12))
                    .foregroundStyle(viewModel.isDiscoverable ? Color.CT.accent : Color.CT.noise)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            flatRowDivider()

            // display name — local, shown to contacts
            profileEditRow(
                label: NSLocalizedString("display_name", comment: ""),
                isEditing: $isEditingDisplayName,
                value: $viewModel.displayName,
                hint: NSLocalizedString("display_name_hint", comment: ""),
                maxLength: MessageSizeLimits.maxDisplayNameCharacters,
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
            flatRowDivider()

            // social recovery
            Button {
                showingSocialRecoverySetup = true
            } label: {
                HStack {
                    Text(socialRecoveryService.isConfigured
                         ? NSLocalizedString("social_recovery_row_active", comment: "")
                         : NSLocalizedString("social_recovery_row_inactive", comment: ""))
                        .font(CTFont.regular(14))
                        .foregroundStyle(socialRecoveryService.isConfigured ? Color.CT.accent : Color.CT.textDim)
                    Spacer()
                    Text("[→]")
                        .font(CTFont.regular(13))
                        .foregroundStyle(Color.CT.accent)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            flatRowDivider()

            // sign out this device
            Button {
                handleLogoutTap(allDevices: false)
            } label: {
                HStack {
                    Text(NSLocalizedString("logout_row", comment: "").lowercased())
                        .font(CTFont.regular(14))
                        .foregroundStyle(Color.CT.text)
                    Spacer()
                    Text("[→]")
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

    // MARK: - Backup Section

    private var backupSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(NSLocalizedString("backup_section", comment: ""))
            flatRowDivider()

            Button { showingExportBackup = true } label: {
                HStack {
                    Text(NSLocalizedString("export_backup", comment: "").lowercased())
                        .font(CTFont.regular(14))
                        .foregroundStyle(Color.CT.text)
                    Spacer()
                    Text("[→]")
                        .font(CTFont.regular(13))
                        .foregroundStyle(Color.CT.accent)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            flatRowDivider()

            Button { showingImportBackup = true } label: {
                HStack {
                    Text(NSLocalizedString("import_backup", comment: "").lowercased())
                        .font(CTFont.regular(14))
                        .foregroundStyle(Color.CT.text)
                    Spacer()
                    Text("[→]")
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

            // sign out ALL devices
            Button {
                handleLogoutTap(allDevices: true)
            } label: {
                HStack {
                    Text(NSLocalizedString("logout_all_row", comment: "").lowercased())
                        .font(CTFont.regular(14))
                        .foregroundStyle(Color.CT.danger.opacity(0.85))
                    Spacer()
                    Text("[→]")
                        .font(CTFont.regular(13))
                        .foregroundStyle(Color.CT.danger.opacity(0.7))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            flatRowDivider()

            // delete account
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

    // MARK: - Logout Logic

    private func handleLogoutTap(allDevices: Bool) {
        pendingLogoutAll = allDevices
        // Guard: if recovery phrase not yet set up, warn before proceeding.
        if recoveryVM.statusLoaded && !recoveryVM.isSetup {
            showingNoBackupWarning = true
        } else if allDevices {
            showingLogoutAllConfirm = true
        } else {
            showingLogoutConfirm = true
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
        hint: String? = nil,
        maxLength: Int? = nil,
        isSaving: Bool = false,
        errorMessage: String? = nil,
        onCommit: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row — entire row is a tap target
            Button {
                if !isEditing.wrappedValue { isEditing.wrappedValue = true }
            } label: {
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
                            .textInputAutocapitalization(.never)
                            .onSubmit {
                                onCommit()
                                isEditing.wrappedValue = false
                            }
                            .onChange(of: value.wrappedValue) { _, newValue in
                                if let max = maxLength, newValue.count > max {
                                    value.wrappedValue = String(newValue.prefix(max))
                                }
                            }
                            .frame(maxWidth: 180)
                        Button {
                            onCommit()
                            isEditing.wrappedValue = false
                        } label: {
                            if isSaving {
                                ProgressView()
                                    .tint(Color.CT.accent)
                                    .scaleEffect(0.8)
                            } else {
                                Text("[→]")
                                    .font(CTFont.bold(13))
                                    .foregroundStyle(Color.CT.accent)
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        HStack(spacing: 8) {
                            Text(value.wrappedValue.isEmpty ? "—" : value.wrappedValue)
                                .font(CTFont.regular(14))
                                .foregroundStyle(Color.CT.text)
                            Text("[edit]")
                                .font(CTFont.regular(12))
                                .foregroundStyle(Color.CT.accent.opacity(0.7))
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Error or hint line
            if let err = errorMessage, !err.isEmpty {
                Text("> [!] \(err)")
                    .font(CTFont.regular(11))
                    .foregroundStyle(Color.CT.danger)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            } else if !isEditing.wrappedValue, let hint {
                Text("> \(hint)")
                    .font(CTFont.regular(11))
                    .foregroundStyle(Color.CT.textDim)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
        }
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
            .environment(AccountRecoveryViewModel())
            .environment(SocialRecoveryService())
            .environment(SettingsViewModel())
    }
    .preferredColorScheme(.dark)
}
#endif
