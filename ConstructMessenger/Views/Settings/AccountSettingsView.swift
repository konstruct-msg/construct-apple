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
    @State private var viewModel = SettingsViewModel()

    @State private var showingImagePicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showingAvatarViewer = false
    @State private var showingDeleteConfirmation = false
    @State private var showingExportAlert = false
    @State private var imageToCrop: UIImage?
    @State private var showingCropView = false

    @State private var originalUsername: String = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                avatarHeader
                Divider()
                identitySection
                Divider()
                privacySection
                Divider()
                dangerSection
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(LocalizedStringKey("account"))
        .navigationBarTitleDisplayMode(.inline)
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
        VStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let image = viewModel.profileImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: AvatarStyle.accountSize, height: AvatarStyle.accountSize)
                            .clipShape(AvatarStyle.squircle(AvatarStyle.accountSize))
                    } else {
                        AvatarStyle.squircle(AvatarStyle.accountSize)
                            .fill(Color.blue.opacity(0.15))
                            .frame(width: AvatarStyle.accountSize, height: AvatarStyle.accountSize)
                            .overlay {
                                Text(viewModel.displayName.prefix(1).uppercased())
                                    .font(.system(size: 40, weight: .semibold))
                                    .foregroundColor(.blue)
                            }
                    }
                }
                .onTapGesture {
                    if viewModel.profileImage != nil { showingAvatarViewer = true }
                    else { showingImagePicker = true }
                }
            }

            if !viewModel.displayName.isEmpty {
                Text(viewModel.displayName)
                    .font(.title3.weight(.semibold))
            }

            Text(viewModel.username.isEmpty
                 ? DisplayNameGenerator.generate(from: viewModel.userId)
                 : "@\(viewModel.username)")
                .font(.subheadline)
                .foregroundColor(.secondary)

        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    // MARK: - Identity Section

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(LocalizedStringKey("account_information"))
            VStack(spacing: 0) {
                // Display Name
                fieldRow(label: LocalizedStringKey("display_name")) {
                    TextField(LocalizedStringKey("display_name"), text: $viewModel.displayName)
                        .onChange(of: viewModel.displayName) { _, newValue in
                            viewModel.saveDisplayName(newValue, authViewModel: authViewModel)
                        }
                }

                Divider().padding(.leading, 16)

                // Username
                fieldRow(label: LocalizedStringKey("username")) {
                    HStack {
                        TextField(LocalizedStringKey("username"), text: $viewModel.username)
                            .font(.body.monospaced())
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit {
                                Task { await viewModel.saveUsername(viewModel.username, authViewModel: authViewModel) }
                            }
                        if viewModel.isSavingUsername {
                            ProgressView().scaleEffect(0.8)
                        } else if viewModel.username != originalUsername {
                            Button(LocalizedStringKey("save")) {
                                Task { await viewModel.saveUsername(viewModel.username, authViewModel: authViewModel) }
                            }
                            .font(.subheadline)
                        } else if viewModel.usernameSaved {
                            Text(LocalizedStringKey("saved"))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .transition(.opacity)
                        }
                    }
                }

                if let error = viewModel.usernameSaveError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground))
        }
    }

    // MARK: - Data & Privacy

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(LocalizedStringKey("data_and_privacy"))
            Button {
                showingExportAlert = true
            } label: {
                HStack {
                    Text(LocalizedStringKey("export_my_data"))
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            sectionFooter(LocalizedStringKey("export_my_data_footer"))
        }
    }

    // MARK: - Danger Zone

    private var dangerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(LocalizedStringKey("danger_zone"))
            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                HStack {
                    Text(LocalizedStringKey("delete_my_account"))
                        .foregroundColor(.red)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
        }
        .padding(.bottom, 32)
    }

    // MARK: - Layout Helpers

    private func fieldRow<Content: View>(label: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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

    private func sectionFooter(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundColor(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 8)
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
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 36, height: 4)
                .padding(.top, 12)
                .padding(.bottom, 24)

            Spacer()

            // Icon
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 52, weight: .light))
                .foregroundColor(.red.opacity(0.85))
                .padding(.bottom, 20)

            Text("delete_my_account")
                .font(.title2).fontWeight(.semibold)
                .padding(.bottom, 8)

            Text("delete_account_confirmation_message")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 32)

            // Countdown ring
            if countdown > 0 && !authViewModel.isLoading {
                ZStack {
                    Circle()
                        .stroke(Color.red.opacity(0.15), lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: CGFloat(7 - countdown) / 7.0)
                        .stroke(Color.red.opacity(0.7), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: countdown)
                    Text("\(countdown)")
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                        .foregroundColor(.red.opacity(0.8))
                }
                .frame(width: 64, height: 64)
                .padding(.bottom, 28)
            }

            // Local-delete fallback — shown after a server-side deletion failure
            if authViewModel.deleteAccountFailed {
                Button {
                    showLocalDeleteConfirm = true
                } label: {
                    Text("delete_account_local_only")
                        .font(.footnote)
                        .underline()
                        .foregroundColor(.red.opacity(0.75))
                }
                .padding(.bottom, 16)
            }

            Spacer()

            // Delete button (full-width, appears after countdown)
            VStack(spacing: 12) {
                if authViewModel.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                } else {
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Text("delete_account")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(countdown > 0 ? Color.red.opacity(0.3) : Color.red)
                            .foregroundColor(.white)
                            .cornerRadius(14)
                    }
                    .disabled(countdown > 0)
                    .animation(.easeInOut(duration: 0.25), value: countdown)
                }

                Button("cancel") {
                    onCancel()
                    dismiss()
                }
                .foregroundColor(.secondary)
                .disabled(authViewModel.isLoading)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 36)
        }
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
    }
}
#endif
