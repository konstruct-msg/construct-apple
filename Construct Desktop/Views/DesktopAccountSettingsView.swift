//
//  DesktopAccountSettingsView.swift
//  Construct Desktop
//
//  Full-featured macOS account settings:
//  avatar, display name, username, export data, delete account.
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
    @State private var showAvatarMenu = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                avatarSection
                Divider().padding(.horizontal, 24)
                identitySection
                Divider().padding(.horizontal, 24)
                privacySection
                Divider().padding(.horizontal, 24)
                dangerSection
            }
            .padding(.bottom, 32)
        }
        .background(DesktopTheme.backgroundPrimary)
        .onAppear {
            viewModel.setContext(viewContext)
            viewModel.loadUserInfo(from: authViewModel)
            originalUsername = viewModel.username
        }
        .onChange(of: viewModel.usernameSaved) { _, saved in
            if saved { originalUsername = viewModel.username }
        }
        .alert("Export My Data", isPresented: $showExportAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Data export is coming soon. Your encrypted messages never leave your device without your key.")
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
        VStack(spacing: 16) {
            ZStack(alignment: .bottomTrailing) {
                avatarImage
                    .frame(width: 96, height: 96)
                    .clipShape(Circle())
                    .onTapGesture { pickAvatar() }

                Button {
                    pickAvatar()
                } label: {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(DesktopTheme.accent)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(DesktopTheme.backgroundPrimary, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: 4)
                .help("Change avatar")
            }

            VStack(spacing: 4) {
                if !viewModel.displayName.isEmpty {
                    Text(viewModel.displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DesktopTheme.textPrimary)
                }
                Text(viewModel.username.isEmpty
                     ? DisplayNameGenerator.generate(from: viewModel.userId)
                     : "@\(viewModel.username)")
                    .font(DesktopTheme.monoFont(12))
                    .foregroundStyle(DesktopTheme.textSecondary)
            }

            if viewModel.profileImage != nil {
                Button("Remove Avatar") {
                    removeAvatar()
                }
                .font(.system(size: 12))
                .foregroundStyle(.red.opacity(0.8))
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    @ViewBuilder
    private var avatarImage: some View {
        if let img = viewModel.profileImage {
            Image(nsImage: img)
                .resizable()
                .scaledToFill()
        } else {
            Circle()
                .fill(DesktopTheme.accent.opacity(0.15))
                .overlay {
                    Text(viewModel.displayName.prefix(1).uppercased())
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(DesktopTheme.accent)
                }
        }
    }

    // MARK: - Identity

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Account Information")

            settingsRow(label: "User ID") {
                Text(viewModel.userId.isEmpty ? "—" : viewModel.userId)
                    .font(DesktopTheme.monoFont(11))
                    .foregroundStyle(DesktopTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            rowDivider

            settingsRow(label: "Display Name") {
                @Bindable var vm = viewModel
                TextField("", text: $vm.displayName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(DesktopTheme.textPrimary)
                    .onChange(of: viewModel.displayName) { _, newValue in
                        viewModel.saveDisplayName(newValue, authViewModel: authViewModel)
                    }
            }

            rowDivider

            settingsRow(label: "Username") {
                @Bindable var vm = viewModel
                HStack(spacing: 8) {
                    TextField("", text: $vm.username)
                        .textFieldStyle(.plain)
                        .font(DesktopTheme.monoFont(13))
                        .foregroundStyle(DesktopTheme.textPrimary)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await saveUsernameIfNeeded() } }

                    if viewModel.isSavingUsername {
                        ProgressView().scaleEffect(0.7)
                    } else if viewModel.username != originalUsername {
                        Button("Save") { Task { await saveUsernameIfNeeded() } }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                    } else if viewModel.usernameSaved {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    }
                }
            }

            if let error = viewModel.usernameSaveError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 10)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Privacy

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Data & Privacy")

            Button {
                showExportAlert = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "square.and.arrow.up")
                        .frame(width: 20)
                        .foregroundStyle(DesktopTheme.accent)
                    Text("Export My Data")
                        .foregroundStyle(DesktopTheme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11))
                        .foregroundStyle(DesktopTheme.textTertiary)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("Your encrypted messages never leave your device without your cryptographic key.")
                .font(.system(size: 11))
                .foregroundStyle(DesktopTheme.textTertiary)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
        }
        .padding(.top, 8)
    }

    // MARK: - Danger Zone

    private var dangerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Danger Zone")

            Button {
                showDeleteConfirm = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "trash")
                        .frame(width: 20)
                        .foregroundStyle(.red)
                    Text("Delete My Account")
                        .foregroundStyle(.red)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11))
                        .foregroundStyle(DesktopTheme.textTertiary)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 8)
    }

    // MARK: - Layout helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(DesktopTheme.textTertiary)
            .tracking(1.2)
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 8)
    }

    private func settingsRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DesktopTheme.textSecondary)
                .frame(width: 130, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    private var rowDivider: some View {
        Divider()
            .padding(.leading, 24 + 130)
            .padding(.trailing, 24)
    }

    // MARK: - Actions

    private func pickAvatar() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Choose"
        panel.message = "Select a profile photo"
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

// MARK: - Delete Account Sheet (macOS)

struct DesktopDeleteAccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthViewModel.self) private var authViewModel

    let onDelete: () -> Void
    let onCancel: () -> Void

    @State private var countdown = 7
    @State private var showLocalDeleteConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.red)
                    .padding(.top, 32)

                Text("Delete Account")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("This will permanently delete your account, all messages, and cryptographic keys. This action cannot be undone.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .padding(.bottom, 24)

            // Countdown ring
            if countdown > 0 && !authViewModel.isLoading {
                ZStack {
                    Circle()
                        .stroke(Color.red.opacity(0.15), lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: CGFloat(7 - countdown) / 7.0)
                        .stroke(Color.red.opacity(0.7),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: countdown)
                    Text("\(countdown)")
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.red.opacity(0.8))
                }
                .frame(width: 64, height: 64)
                .padding(.bottom, 24)
            }

            if authViewModel.deleteAccountFailed {
                Button("Delete locally only (offline mode)") {
                    showLocalDeleteConfirm = true
                }
                .font(.footnote)
                .foregroundStyle(.red.opacity(0.75))
                .padding(.bottom, 12)
            }

            Spacer()

            // Actions
            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
                .keyboardShortcut(.escape)
                .disabled(authViewModel.isLoading)

                Spacer()

                if authViewModel.isLoading {
                    ProgressView()
                } else {
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Text("Delete My Account")
                            .frame(minWidth: 140)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(countdown > 0)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(width: 400, height: 360)
        .alert("Delete Locally?", isPresented: $showLocalDeleteConfirm) {
            Button("Delete Locally", role: .destructive) {
                authViewModel.deleteAccountLocally()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all local data. The server account may still exist if the network request failed.")
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
        .frame(width: 500, height: 700)
}

