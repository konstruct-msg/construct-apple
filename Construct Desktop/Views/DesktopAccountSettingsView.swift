//
//  DesktopAccountSettingsView.swift
//  Construct Desktop
//
//  CT-terminal-style macOS identity settings:
//  hexagonal avatar, display name, username, export data, delete account.
//

import SwiftUI
import CoreData
import AppKit
import UniformTypeIdentifiers

struct DesktopAccountSettingsView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(AuthViewModel.self) private var authViewModel

    @State private var viewModel = SettingsViewModel()
    @State private var originalUsername: String = ""
    @State private var showDeleteConfirm = false
    @State private var showExportAlert = false

    var body: some View {
        @Bindable var vm = viewModel
        ScrollView {
            VStack(spacing: 0) {
                avatarSection
                CTSep(style: .thick)
                identitySection
                CTSep(style: .thick)
                privacySection
                CTSep(style: .thick)
                dangerSection
                CTSep(style: .thick)

                Text(NSLocalizedString("changes_encrypted_footer", comment: ""))
                    .font(CTFont.regular(11))
                    .foregroundStyle(Color.CT.accent.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
            }
            .padding(.bottom, 24)
        }
        .background(Color.CT.bg)
        .onAppear {
            viewModel.setContext(viewContext)
            viewModel.loadUserInfo(from: authViewModel)
            originalUsername = viewModel.username
        }
        .onChange(of: viewModel.usernameSaved) { _, saved in
            if saved { originalUsername = viewModel.username }
        }
        .alert(NSLocalizedString("export_my_data", comment: ""), isPresented: $showExportAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(NSLocalizedString("export_coming_soon_message", comment: ""))
        }
        .sheet(isPresented: $showDeleteConfirm) {
            DesktopDeleteAccountSheet(
                onDelete: { authViewModel.deleteAccount() },
                onCancel: { showDeleteConfirm = false }
            )
            .environment(authViewModel)
        }
    }

    // MARK: - Avatar

    private var avatarSection: some View {
        VStack(spacing: 14) {
            let seed = viewModel.userId
            let initials: String = {
                let name = viewModel.displayName.isEmpty
                    ? DisplayNameGenerator.generate(from: viewModel.userId)
                    : viewModel.displayName
                let parts = name.split(separator: " ")
                if parts.count >= 2 {
                    return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
                }
                return String(name.prefix(2)).uppercased()
            }()

            if let img = viewModel.profileImage {
                CTHexAvatar(initials: initials,
                            image: Image(nsImage: img),
                            size: .large,
                            colorSeed: seed)
                    .onTapGesture { pickAvatar() }
            } else {
                CTHexAvatar(initials: initials, size: .large, colorSeed: seed)
                    .onTapGesture { pickAvatar() }
            }

            Button { pickAvatar() } label: {
                Text("[\(NSLocalizedString("change_photo", comment: ""))]")
                    .font(CTFont.regular(13))
                    .foregroundStyle(Color.CT.accent)
            }
            .buttonStyle(.plain)

            if viewModel.profileImage != nil {
                Button { removeAvatar() } label: {
                    Text("[\(NSLocalizedString("remove_avatar", comment: ""))]")
                        .font(CTFont.regular(12))
                        .foregroundStyle(Color.CT.danger)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    // MARK: - Identity

    private var identitySection: some View {
        @Bindable var vm = viewModel
        return VStack(alignment: .leading, spacing: 0) {
            CTSettingsSectionHeader(title: NSLocalizedString("identity_section", comment: ""))

            // User ID (read-only)
            HStack {
                Text(NSLocalizedString("user_id", comment: ""))
                    .font(CTFont.regular(13))
                    .foregroundStyle(Color.CT.textDim)
                    .frame(width: 120, alignment: .leading)
                let uid = viewModel.userId
                let short = uid.count > 16 ? "\(uid.prefix(8))…\(uid.suffix(4))" : uid
                Text(short.isEmpty ? "—" : short)
                    .font(CTFont.regular(11))
                    .foregroundStyle(Color.CT.textDim)
                    .textSelection(.enabled)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 10)

            CTSep(style: .thin)

            // Display Name (editable)
            HStack {
                Text(NSLocalizedString("display_name", comment: ""))
                    .font(CTFont.regular(13))
                    .foregroundStyle(Color.CT.textDim)
                    .frame(width: 120, alignment: .leading)
                TextField("", text: $vm.displayName)
                    .textFieldStyle(.plain)
                    .font(CTFont.regular(13))
                    .foregroundStyle(Color.CT.text)
                    .onChange(of: vm.displayName) { _, val in
                        viewModel.saveDisplayName(val, authViewModel: authViewModel)
                    }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)

            CTSep(style: .thin)

            // Username (editable, server-validated)
            HStack {
                Text(NSLocalizedString("username", comment: ""))
                    .font(CTFont.regular(13))
                    .foregroundStyle(Color.CT.textDim)
                    .frame(width: 120, alignment: .leading)
                TextField("", text: $vm.username)
                    .textFieldStyle(.plain)
                    .font(CTFont.regular(13))
                    .foregroundStyle(Color.CT.text)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await saveUsernameIfNeeded() } }
                Spacer()
                if viewModel.isSavingUsername {
                    ProgressView().scaleEffect(0.6)
                } else if viewModel.username != originalUsername {
                    Button(NSLocalizedString("save", comment: "")) {
                        Task { await saveUsernameIfNeeded() }
                    }
                    .font(CTFont.regular(11))
                    .foregroundStyle(Color.CT.accent)
                    .buttonStyle(.plain)
                } else if viewModel.usernameSaved {
                    Text("[ok]")
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.accent)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)

            if let error = viewModel.usernameSaveError {
                Text(error)
                    .font(CTFont.regular(11))
                    .foregroundStyle(Color.CT.danger)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Privacy

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            CTSettingsSectionHeader(title: NSLocalizedString("privacy", comment: ""))

            Button { showExportAlert = true } label: {
                HStack {
                    Text(NSLocalizedString("export_my_data", comment: ""))
                        .font(CTFont.regular(13))
                        .foregroundStyle(Color.CT.text)
                    Spacer()
                    Text("[→]").font(CTFont.regular(12)).foregroundStyle(Color.CT.textDim)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Danger Zone

    private var dangerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            CTSettingsSectionHeader(title: NSLocalizedString("danger_zone", comment: ""), color: Color.CT.danger)

            Button { showDeleteConfirm = true } label: {
                HStack {
                    Text(NSLocalizedString("delete_account", comment: ""))
                        .font(CTFont.regular(13))
                        .foregroundStyle(Color.CT.danger)
                    Spacer()
                    Text("[→]").font(CTFont.regular(12)).foregroundStyle(Color.CT.danger.opacity(0.6))
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Actions

    private func pickAvatar() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = NSLocalizedString("save", comment: "")
        guard panel.runModal() == .OK, let url = panel.url,
              let image = NSImage(contentsOf: url) else { return }
        viewModel.saveAvatar(image, authViewModel: authViewModel)
    }

    private func removeAvatar() {
        guard let context = viewModel.viewContextPublic, !viewModel.userId.isEmpty else { return }
        let req = User.fetchRequest()
        req.predicate = NSPredicate(format: "id == %@", viewModel.userId)
        req.fetchLimit = 1
        if let user = try? context.fetch(req).first {
            user.avatarData = nil
            try? context.save()
            viewModel.profileImage = nil
        }
    }

    private func saveUsernameIfNeeded() async {
        await viewModel.saveUsername(viewModel.username, authViewModel: authViewModel)
    }
}

// MARK: - Delete Account Sheet (macOS, CT-style)

struct DesktopDeleteAccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthViewModel.self) private var authViewModel

    let onDelete: () -> Void
    let onCancel: () -> Void

    @State private var countdown = 7
    @State private var showLocalDeleteConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            // CT nav bar
            CTNavBar(
                title: NSLocalizedString("delete_account", comment: ""),
                showBack: true,
                backAction: { onCancel(); dismiss() }
            )

            Rectangle().fill(Color.CT.noise).frame(height: 1)

            Spacer()

            // Warning block
            VStack(spacing: 8) {
                Text("[!]")
                    .font(CTFont.bold(32))
                    .foregroundStyle(Color.CT.danger)

                Text(NSLocalizedString("delete_account", comment: "").uppercased())
                    .font(CTFont.bold(14))
                    .foregroundStyle(Color.CT.danger)
                    .tracking(2)

                Text(NSLocalizedString("delete_account_warning", comment: ""))
                    .font(CTFont.regular(12))
                    .foregroundStyle(Color.CT.textDim)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 32)
                    .padding(.top, 4)
            }
            .padding(.bottom, 24)

            // Countdown
            if countdown > 0 && !authViewModel.isLoading {
                Text("[ \(countdown) ]")
                    .font(CTFont.bold(22))
                    .foregroundStyle(Color.CT.danger)
                    .padding(.bottom, 24)
            }

            if authViewModel.deleteAccountFailed {
                Button {
                    showLocalDeleteConfirm = true
                } label: {
                    Text(NSLocalizedString("delete_locally_only", comment: ""))
                        .font(CTFont.regular(12))
                        .foregroundStyle(Color.CT.danger.opacity(0.75))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 12)
            }

            Spacer()

            // Actions
            Rectangle().fill(Color.CT.noise).frame(height: 1)
            HStack(spacing: 16) {
                Button {
                    onCancel()
                    dismiss()
                } label: {
                    Text("[cancel]")
                        .font(CTFont.regular(13))
                        .foregroundStyle(Color.CT.textDim)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape)
                .disabled(authViewModel.isLoading)

                Spacer()

                if authViewModel.isLoading {
                    ProgressView()
                } else {
                    Button {
                        onDelete()
                    } label: {
                        Text("[\(NSLocalizedString("delete_account", comment: "").uppercased())]")
                            .font(CTFont.bold(13))
                            .foregroundStyle(countdown > 0 ? Color.CT.danger.opacity(0.35) : Color.CT.danger)
                    }
                    .buttonStyle(.plain)
                    .disabled(countdown > 0)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 400, height: 340)
        .ctBackground()
        .alert(NSLocalizedString("delete_locally_question", comment: ""), isPresented: $showLocalDeleteConfirm) {
            Button(NSLocalizedString("delete_locally_action", comment: ""), role: .destructive) {
                authViewModel.deleteAccountLocally()
            }
            Button(NSLocalizedString("cancel", comment: ""), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("delete_locally_message", comment: ""))
        }
        .task {
            while countdown > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard countdown > 0 else { break }
                countdown -= 1
            }
        }
        .onChange(of: authViewModel.isAuthenticated) { _, isAuthenticated in
            if !isAuthenticated { dismiss() }
        }
    }
}

#Preview {
    DesktopAccountSettingsView()
        .environment(AuthViewModel(context: PersistenceController.shared.container.viewContext))
        .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
        .frame(width: 500, height: 600)
}

