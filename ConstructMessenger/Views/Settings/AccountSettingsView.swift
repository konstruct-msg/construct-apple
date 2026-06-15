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
    @State private var showingSendNearby = false
    @State private var showingReceiveNearby = false
    @State private var imageToCrop: UIImage?
    @State private var showingCropView = false
    @State private var isEditingProfile = false
    @State private var draftUsername: String = ""
    @State private var draftDisplayName: String = ""
    @State private var showingDiscardProfileChangesConfirm = false
    @State private var shouldDismissAfterDiscard = false

    // Logout flow
    @State private var showingLogoutConfirm = false
    @State private var showingLogoutAllConfirm = false
    @State private var showingNoBackupWarning = false
    @State private var showingRecoverySetup = false
    @State private var showingSocialRecoverySetup = false
    @State private var pendingLogoutAll = false  // which logout action was requested before backup check

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            flatDivider(thick: true)

            ScrollView {
                LazyVStack(spacing: 0) {
                    avatarHeader
                    flatDivider(thick: true)
                    identitySection
                    flatDivider(thick: true)
                    accountSection
                        .opacity(isEditingProfile ? AccountSettingsLayout.sectionDisabledOpacity : 1)
                        .disabled(isEditingProfile)
                    flatDivider(thick: true)
                    backupSection
                        .opacity(isEditingProfile ? AccountSettingsLayout.sectionDisabledOpacity : 1)
                        .disabled(isEditingProfile)
                    flatDivider(thick: true)
                    dangerSection
                        .opacity(isEditingProfile ? AccountSettingsLayout.sectionDisabledOpacity : 1)
                        .disabled(isEditingProfile)
                    flatDivider(thick: true)

                    Text(NSLocalizedString("changes_encrypted_footer", comment: ""))
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.accent.opacity(AccountSettingsLayout.footerTextOpacity))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, AccountSettingsLayout.footerHorizontalPadding)
                        .padding(.vertical, AccountSettingsLayout.footerVerticalPadding)
                }
            }
        }
        .background(Color.CT.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            viewModel.setContext(viewContext)
            if viewModel.needsUserInfoRefresh(from: authViewModel) {
                viewModel.loadUserInfo(from: authViewModel)
            }
            syncDraftProfileFields()
        }
        .onChange(of: viewModel.username) { _, _ in
            if !isEditingProfile { syncDraftProfileFields() }
        }
        .onChange(of: viewModel.displayName) { _, _ in
            if !isEditingProfile { syncDraftProfileFields() }
        }
        .sheet(isPresented: $showingExportBackup) {
            ExportBackupView()
                .environment(\.managedObjectContext, viewContext)
        }
        .sheet(isPresented: $showingImportBackup) {
            ImportBackupView()
        }
        .sheet(isPresented: $showingSendNearby) {
            SendBackupNearbyView()
                .environment(\.managedObjectContext, viewContext)
        }
        .sheet(isPresented: $showingReceiveNearby) {
            ReceiveBackupNearbyView()
        }
        .sheet(isPresented: $showingDeleteConfirmation) {
            DeleteAccountConfirmationView(onDelete: { authViewModel.deleteAccount() },
                                         onCancel: { showingDeleteConfirmation = false })
            .environment(authViewModel)
        }
        .sheet(isPresented: $showingAvatarViewer) {
            AvatarViewerSheet(image: viewModel.profileImage, onChangeAvatar: {
                showingAvatarViewer = false
                DispatchQueue.main.asyncAfter(deadline: .now() + AccountSettingsLayout.postAvatarPickerDelay) {
                    showingImagePicker = true
                }
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
        .alert("account_discard_changes_title", isPresented: $showingDiscardProfileChangesConfirm) {
            Button("account_discard_changes_discard", role: .destructive) {
                discardProfileEditingChanges()
                if shouldDismissAfterDiscard {
                    dismiss()
                }
            }
            Button("account_discard_changes_keep_editing", role: .cancel) {}
        } message: {
            Text("account_discard_changes_message")
        }
    }

    private var navigationBar: some View {
        CTNavBar(
            title: isEditingProfile
                ? NSLocalizedString("edit_identity", comment: "")
                : NSLocalizedString("account", comment: ""),
            showBack: !isEditingProfile,
            leadingSystemImage: isEditingProfile ? "xmark" : nil,
            trailingSymbol: isEditingProfile ? NSLocalizedString("save", comment: "") : nil,
            trailingSystemImage: isEditingProfile ? nil : "square.and.pencil",
            trailingColor: viewModel.isSavingUsername ? Color.CT.textDim : Color.CT.accent,
            leadingAction: { handleProfileEditCancelTap() },
            backAction: { handleBackTap() },
            trailingAction: { handleProfileEditActionTap() }
        )
    }

    // MARK: - Avatar Header

    private var avatarHeader: some View {
        VStack(spacing: AccountSettingsLayout.avatarSectionSpacing) {
            MainAvatarView(
                userId: viewModel.userId,
                displayName: viewModel.displayName,
                image: viewModel.profileImage,
                size: AvatarStyle.accountSize,
                isActive: false
            )
            .onTapGesture {
                guard !isEditingProfile else { return }
                if viewModel.profileImage != nil { showingAvatarViewer = true }
                else { showingImagePicker = true }
            }
            .opacity(isEditingProfile ? AccountSettingsLayout.avatarSectionEditingOpacity : 1)

            Button {
                guard !isEditingProfile else { return }
                showingImagePicker = true
            } label: {
                Text("[\(NSLocalizedString("change_photo", comment: ""))]")
                    .font(CTFont.regular(13))
                    .foregroundStyle(isEditingProfile ? Color.CT.textDim : Color.CT.accent)
            }
            .buttonStyle(.plain)
            .disabled(isEditingProfile)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AccountSettingsLayout.avatarSectionVerticalPadding)
    }

    // MARK: - Identity Section

    private var identitySection: some View {
        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader(NSLocalizedString("identity_section", comment: ""))
            if isEditingProfile {
                Text(NSLocalizedString("account_editing_profile", comment: ""))
                    .font(CTFont.regular(11))
                    .foregroundStyle(Color.CT.accent)
                    .padding(.horizontal, AccountSettingsLayout.sectionHintHorizontalPadding)
                    .padding(.bottom, AccountSettingsLayout.sectionHintBottomPadding)
            }
            flatRowDivider()

            profileEditableRow(
                label: NSLocalizedString("username", comment: ""),
                value: $draftUsername,
                hint: NSLocalizedString("username_hint", comment: ""),
                isEditing: isEditingProfile,
                isSaving: viewModel.isSavingUsername,
                errorMessage: viewModel.usernameSaveError,
                maxLength: MessageSizeLimits.maxUsernameCharacters,
                lowercased: true
            )
            flatRowDivider()
            HStack(spacing: AccountSettingsLayout.discoverableRowSpacing) {
                Text(viewModel.isDiscoverable
                    ? NSLocalizedString("searchable_indicator", comment: "")
                    : NSLocalizedString("searchable_indicator_off", comment: ""))
                    .font(CTFont.regular(12))
                    .foregroundStyle(viewModel.isDiscoverable ? Color.CT.accent : Color.CT.noise)
            }
            .padding(.horizontal, AccountSettingsLayout.discoverableRowHorizontalPadding)
            .padding(.vertical, AccountSettingsLayout.discoverableRowVerticalPadding)
            flatRowDivider()

            profileEditableRow(
                label: NSLocalizedString("display_name", comment: ""),
                value: $draftDisplayName,
                hint: NSLocalizedString("display_name_hint", comment: ""),
                isEditing: isEditingProfile,
                maxLength: MessageSizeLimits.maxDisplayNameCharacters
            )
            flatRowDivider()

            // status — placeholder, not yet implemented
            profileRow(label: NSLocalizedString("status", comment: "")) {
                HStack(spacing: AccountSettingsLayout.inlineStatusSpacing) {
                    Text("ONLINE")
                        .font(CTFont.regular(14))
                        .foregroundStyle(Color.CT.accent)
                    Image(systemName: "chevron.right")
                        .font(CTFont.regular(13))
                        .foregroundStyle(Color.CT.accent.opacity(AccountSettingsLayout.inlineStatusAccentOpacity))
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

            navigationRow(
                label: NSLocalizedString("linked_devices", comment: ""),
                labelColor: Color.CT.textDim,
                trailingText: "[\(NSLocalizedString("manage_action", comment: ""))]"
            ) {
                DevicesView()
            }
            flatRowDivider()

            // social recovery
            actionRow(
                label: socialRecoveryService.isConfigured
                    ? NSLocalizedString("social_recovery_row_active", comment: "")
                    : NSLocalizedString("social_recovery_row_inactive", comment: ""),
                labelColor: socialRecoveryService.isConfigured ? Color.CT.accent : Color.CT.textDim
            ) {
                showingSocialRecoverySetup = true
            }
            flatRowDivider()

            // sign out this device
            actionRow(label: NSLocalizedString("logout_row", comment: "")) {
                handleLogoutTap(allDevices: false)
            }
        }
    }

    // MARK: - Backup Section

    private var backupSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(NSLocalizedString("backup_section", comment: ""))
            flatRowDivider()

            actionRow(label: NSLocalizedString("export_backup", comment: "")) { showingExportBackup = true }
            flatRowDivider()

            actionRow(label: NSLocalizedString("import_backup", comment: "")) { showingImportBackup = true }
            flatRowDivider()

            actionRow(label: NSLocalizedString("transfer_send_nearby", comment: "")) { showingSendNearby = true }
            flatRowDivider()

            actionRow(label: NSLocalizedString("transfer_receive_nearby", comment: "")) { showingReceiveNearby = true }
        }
    }

    // MARK: - Danger Zone

    private var dangerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(NSLocalizedString("danger_zone", comment: ""), color: Color.CT.danger)
            flatRowDivider()

            // sign out ALL devices
            actionRow(
                label: NSLocalizedString("logout_all_row", comment: ""),
                labelColor: Color.CT.danger.opacity(AccountSettingsLayout.dangerPrimaryOpacity),
                accessoryColor: Color.CT.danger.opacity(AccountSettingsLayout.dangerSecondaryOpacity)
            ) {
                handleLogoutTap(allDevices: true)
            }
            flatRowDivider()

            // delete account
            actionRow(
                label: NSLocalizedString("delete_account_row", comment: ""),
                labelColor: Color.CT.danger,
                accessory: .text("[\(NSLocalizedString("delete_action", comment: ""))]"),
                accessoryColor: Color.CT.danger.opacity(AccountSettingsLayout.dangerSecondaryOpacity)
            ) {
                showingDeleteConfirmation = true
            }
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
            .fill(thick ? Color.CT.noise : Color.CT.noise.opacity(AccountSettingsLayout.dividerRegularOpacity))
            .frame(height: AccountSettingsLayout.dividerHeight)
    }

    private func flatRowDivider() -> some View {
        Rectangle()
            .fill(Color.CT.noise.opacity(AccountSettingsLayout.dividerRowOpacity))
            .frame(height: AccountSettingsLayout.dividerHeight)
            .padding(.horizontal, AccountSettingsLayout.dividerHorizontalPadding)
    }

    private func sectionHeader(_ title: String, color: Color = Color.CT.accent) -> some View {
        HStack(spacing: AccountSettingsLayout.sectionHeaderSpacing) {
            Text(">")
                .font(CTFont.bold(12))
                .foregroundStyle(color)
            Text(title.uppercased())
                .font(CTFont.bold(12))
                .foregroundStyle(color)
                .tracking(AccountSettingsLayout.sectionHeaderTracking)
        }
        .padding(.horizontal, AccountSettingsLayout.sectionHeaderHorizontalPadding)
        .padding(.vertical, AccountSettingsLayout.sectionHeaderVerticalPadding)
    }

    private func profileRow<V: View>(label: String, @ViewBuilder value: () -> V) -> some View {
        HStack {
            Text(label.lowercased())
                .font(CTFont.regular(14))
                .foregroundStyle(Color.CT.textDim)
            Spacer()
            value()
        }
        .padding(.horizontal, AccountSettingsLayout.rowHorizontalPadding)
        .padding(.vertical, AccountSettingsLayout.rowVerticalPadding)
    }

    private enum RowAccessory {
        case chevron
        case text(String)
    }

    private func actionRow(
        label: String,
        labelColor: Color = Color.CT.text,
        accessory: RowAccessory = .chevron,
        accessoryColor: Color = Color.CT.accent,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(label.lowercased())
                    .font(CTFont.regular(14))
                    .foregroundStyle(labelColor)
                Spacer()
                rowAccessoryView(accessory, color: accessoryColor)
            }
            .padding(.horizontal, AccountSettingsLayout.rowHorizontalPadding)
            .padding(.vertical, AccountSettingsLayout.rowVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func navigationRow<Destination: View>(
        label: String,
        labelColor: Color = Color.CT.text,
        trailingText: String? = nil,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink(destination: destination()) {
            HStack {
                Text(label.lowercased())
                    .font(CTFont.regular(14))
                    .foregroundStyle(labelColor)
                Spacer()
                if let trailingText {
                    Text(trailingText)
                        .font(CTFont.regular(13))
                        .foregroundStyle(Color.CT.accent)
                } else {
                    rowAccessoryView(.chevron, color: Color.CT.accent)
                }
            }
            .padding(.horizontal, AccountSettingsLayout.rowHorizontalPadding)
            .padding(.vertical, AccountSettingsLayout.rowVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func rowAccessoryView(_ accessory: RowAccessory, color: Color) -> some View {
        switch accessory {
        case .chevron:
            Image(systemName: "chevron.right")
                .font(CTFont.regular(13))
                .foregroundStyle(color)
        case .text(let value):
            Text(value)
                .font(CTFont.regular(13))
                .foregroundStyle(color)
        }
    }

    private func profileEditableRow(
        label: String,
        value: Binding<String>,
        hint: String? = nil,
        isEditing: Bool,
        isSaving: Bool = false,
        errorMessage: String? = nil,
        maxLength: Int? = nil,
        lowercased: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if isEditing {
                // Vertical layout: the label becomes a placeholder inside the
                // field, the field gets a visible bottom underline. Makes it
                // unambiguous to the user where input lands.
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField(label.lowercased(), text: value)
                            .font(CTFont.regular(15))
                            .foregroundStyle(Color.CT.text)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(lowercased ? .never : .words)
                            .onChange(of: value.wrappedValue) { _, newValue in
                                var updated = newValue
                                if lowercased {
                                    updated = updated.lowercased()
                                }
                                if let max = maxLength, updated.count > max {
                                    updated = String(updated.prefix(max))
                                }
                                if updated != value.wrappedValue {
                                    value.wrappedValue = updated
                                }
                            }

                        if isSaving {
                            ProgressView()
                                .tint(Color.CT.accent)
                                .scaleEffect(AccountSettingsLayout.editableSavingIndicatorScale)
                        }
                    }
                    Rectangle()
                        .fill(Color.CT.accent)
                        .frame(height: 1)
                }
                .padding(.horizontal, AccountSettingsLayout.rowHorizontalPadding)
                .padding(.vertical, AccountSettingsLayout.rowVerticalPadding)
            } else {
                HStack {
                    Text(label.lowercased())
                        .font(CTFont.regular(14))
                        .foregroundStyle(Color.CT.textDim)
                    Spacer()
                    Text(value.wrappedValue.isEmpty ? "—" : value.wrappedValue)
                        .font(CTFont.regular(14))
                        .foregroundStyle(Color.CT.text)
                }
                .padding(.horizontal, AccountSettingsLayout.rowHorizontalPadding)
                .padding(.vertical, AccountSettingsLayout.rowVerticalPadding)
            }

            if let err = errorMessage, !err.isEmpty {
                Text("> [!] \(err)")
                    .font(CTFont.regular(11))
                    .foregroundStyle(Color.CT.danger)
                    .padding(.horizontal, AccountSettingsLayout.sectionHintHorizontalPadding)
                    .padding(.bottom, AccountSettingsLayout.sectionHintBottomPadding)
            } else if !isEditing, let hint {
                Text("> \(hint)")
                    .font(CTFont.regular(11))
                    .foregroundStyle(Color.CT.textDim)
                    .padding(.horizontal, AccountSettingsLayout.sectionHintHorizontalPadding)
                    .padding(.bottom, AccountSettingsLayout.sectionHintBottomPadding)
            }
        }
    }

    private func syncDraftProfileFields() {
        draftUsername = viewModel.username
        draftDisplayName = viewModel.displayName
    }

    private func discardProfileEditingChanges() {
        syncDraftProfileFields()
        viewModel.usernameSaveError = nil
        shouldDismissAfterDiscard = false
        isEditingProfile = false
    }

    private var hasUnsavedProfileChanges: Bool {
        let usernameChanged = draftUsername.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            != viewModel.username
        let displayNameChanged = draftDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
            != viewModel.displayName
        return usernameChanged || displayNameChanged
    }

    private func handleBackTap() {
        if isEditingProfile {
            if hasUnsavedProfileChanges {
                promptDiscardProfileChanges(dismissAfterDiscard: true)
                return
            }
            discardProfileEditingChanges()
        }
        dismiss()
    }

    private func handleProfileEditActionTap() {
        guard !viewModel.isSavingUsername else { return }
        if isEditingProfile {
            Task { await saveProfileEdits() }
        } else {
            syncDraftProfileFields()
            viewModel.usernameSaveError = nil
            isEditingProfile = true
        }
    }

    private func handleProfileEditCancelTap() {
        guard isEditingProfile else { return }
        if hasUnsavedProfileChanges {
            promptDiscardProfileChanges(dismissAfterDiscard: false)
        } else {
            discardProfileEditingChanges()
        }
    }

    private func promptDiscardProfileChanges(dismissAfterDiscard: Bool) {
        shouldDismissAfterDiscard = dismissAfterDiscard
        showingDiscardProfileChangesConfirm = true
    }

    private func saveProfileEdits() async {
        guard !viewModel.isSavingUsername else { return }

        let trimmedDisplayName = draftDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedDisplayName.count > MessageSizeLimits.maxDisplayNameCharacters {
            draftDisplayName = String(trimmedDisplayName.prefix(MessageSizeLimits.maxDisplayNameCharacters))
        } else {
            draftDisplayName = trimmedDisplayName
        }

        draftUsername = draftUsername.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let didChangeDisplayName = draftDisplayName != viewModel.displayName
        let didChangeUsername = draftUsername != viewModel.username

        if didChangeDisplayName {
            viewModel.saveDisplayName(draftDisplayName, authViewModel: authViewModel)
            draftDisplayName = viewModel.displayName
        }

        if didChangeUsername {
            await viewModel.saveUsername(draftUsername, authViewModel: authViewModel)
            draftUsername = viewModel.username
        }

        if viewModel.usernameSaveError == nil && !hasUnsavedProfileChanges {
            isEditingProfile = false
        }
    }

}


// MARK: - Delete Account Confirmation View
struct DeleteAccountConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthViewModel.self) private var authViewModel

    let onDelete: () -> Void
    let onCancel: () -> Void

    /// Undo-send pattern: nil = idle (delete button is the primary action and
    /// fires immediately on tap); non-nil = countdown is running, the same
    /// button is now an abort, and on reaching 0 the actual delete RPC fires.
    /// Gives the user a 10s window to change their mind AFTER committing.
    @State private var pendingSecondsLeft: Int? = nil
    @State private var pendingTask: Task<Void, Never>? = nil
    @State private var showLocalDeleteConfirm = false

    private static let abortWindowSeconds = 10

    var body: some View {
        VStack(spacing: DeleteAccountSheetLayout.rootSpacing) {
            // Drag indicator
            Capsule()
                .fill(Color.CT.noise)
                .frame(
                    width: DeleteAccountSheetLayout.dragIndicatorWidth,
                    height: DeleteAccountSheetLayout.dragIndicatorHeight
                )
                .padding(.top, DeleteAccountSheetLayout.dragIndicatorTopPadding)
                .padding(.bottom, DeleteAccountSheetLayout.dragIndicatorBottomPadding)

            Spacer()

            Text(LocalizedStringKey("delete_my_account"))
                .font(CTFont.bold(20))
                .foregroundStyle(Color.CT.text)
                .padding(.bottom, DeleteAccountSheetLayout.titleBottomPadding)

            Text(LocalizedStringKey("delete_account_confirmation_message"))
                .font(CTFont.regular(14))
                .foregroundStyle(Color.CT.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DeleteAccountSheetLayout.messageHorizontalPadding)
                .padding(.bottom, DeleteAccountSheetLayout.messageBottomPadding)

            // Local-delete fallback — shown after a server-side deletion failure
            if authViewModel.deleteAccountFailed {
                Button {
                    showLocalDeleteConfirm = true
                } label: {
                    Text(LocalizedStringKey("delete_account_local_only"))
                        .font(CTFont.regular(12))
                        .underline()
                        .foregroundStyle(Color.CT.danger.opacity(DeleteAccountSheetLayout.localDeleteWarningOpacity))
                }
                .padding(.bottom, DeleteAccountSheetLayout.localDeleteActionBottomPadding)
            }

            Spacer()

            // Delete-or-abort button (full-width)
            VStack(spacing: DeleteAccountSheetLayout.actionsSpacing) {
                if authViewModel.isLoading {
                    ProgressView()
                        .tint(Color.CT.danger)
                        .frame(maxWidth: .infinity)
                        .frame(height: DeleteAccountSheetLayout.actionButtonHeight)
                } else if let secondsLeft = pendingSecondsLeft {
                    abortButton(secondsLeft: secondsLeft)
                } else {
                    Button {
                        startPendingDelete()
                    } label: {
                        Text(LocalizedStringKey("delete_account"))
                            .font(CTFont.bold(16))
                            .frame(maxWidth: .infinity)
                            .frame(height: DeleteAccountSheetLayout.actionButtonHeight)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.CT.danger.opacity(DeleteAccountSheetLayout.deleteButtonActiveFillOpacity))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(
                                                Color.CT.danger.opacity(DeleteAccountSheetLayout.deleteButtonActiveStrokeOpacity),
                                                lineWidth: DeleteAccountSheetLayout.deleteButtonStrokeWidth
                                            )
                                    )
                            )
                            .foregroundStyle(Color.CT.danger)
                    }
                }

                // Cancel hidden during the abort window — the big button IS the abort
                // (a separate "Cancel" beside it would let the user cancel-abort,
                // i.e., proceed with deletion. Confusing. Keep one path.)
                if pendingSecondsLeft == nil {
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
            }
            .padding(.horizontal, DeleteAccountSheetLayout.actionsHorizontalPadding)
            .padding(.bottom, DeleteAccountSheetLayout.actionsBottomPadding)
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
        .onChange(of: authViewModel.isLoading) { _, loading in
            // Reset failed state when a new deletion attempt starts
            if loading { authViewModel.deleteAccountFailed = false }
        }
        .onDisappear {
            pendingTask?.cancel()
            pendingTask = nil
            pendingSecondsLeft = nil
        }
        // On macOS Catalyst, sheets are child windows and don't auto-close
        // when parent view changes — explicitly dismiss when account is deleted.
        .onChange(of: authViewModel.isAuthenticated) { _, isAuthenticated in
            if !isAuthenticated { dismiss() }
        }
    }

    /// Pending-state button: the same red rectangle as the idle delete, but
    /// the tap now aborts. Below it a thin progress bar grows left-to-right
    /// as the abort window elapses.
    private func abortButton(secondsLeft: Int) -> some View {
        let total = Self.abortWindowSeconds
        let elapsedFraction = CGFloat(max(0, total - secondsLeft)) / CGFloat(total)
        return VStack(spacing: 6) {
            Button {
                abortPendingDelete()
            } label: {
                Text(String(format: NSLocalizedString("delete_account_abort_hint", comment: ""), secondsLeft))
                    .font(CTFont.bold(15))
                    .frame(maxWidth: .infinity)
                    .frame(height: DeleteAccountSheetLayout.actionButtonHeight)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.CT.danger.opacity(DeleteAccountSheetLayout.deleteButtonIdleFillOpacity))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(
                                        Color.CT.danger,
                                        lineWidth: DeleteAccountSheetLayout.deleteButtonStrokeWidth
                                    )
                            )
                    )
                    .foregroundStyle(Color.CT.danger)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.CT.danger.opacity(0.2))
                    Rectangle()
                        .fill(Color.CT.danger)
                        .frame(width: geo.size.width * elapsedFraction)
                        .animation(.linear(duration: 1.0), value: elapsedFraction)
                }
            }
            .frame(height: 3)
        }
    }

    private func startPendingDelete() {
        let total = Self.abortWindowSeconds
        pendingSecondsLeft = total
        pendingTask?.cancel()
        pendingTask = Task { @MainActor in
            for n in (0..<total).reversed() {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                pendingSecondsLeft = n
            }
            if Task.isCancelled { return }
            // Window elapsed without abort — actually delete
            pendingSecondsLeft = nil
            pendingTask = nil
            onDelete()
        }
    }

    private func abortPendingDelete() {
        pendingTask?.cancel()
        pendingTask = nil
        pendingSecondsLeft = nil
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
            .navigationBarTitleDisplayMode(.inline)
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
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
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
