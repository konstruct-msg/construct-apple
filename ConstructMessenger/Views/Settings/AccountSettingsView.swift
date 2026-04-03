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
            VStack(spacing: 20) {
                avatarHeader
                identitySection
                privacySection
                dangerSection
            }
            .padding(.vertical, 20)
        }
        .background(Color.CT.bg.ignoresSafeArea())
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.CT.bgMsg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(NSLocalizedString("account", comment: ""))
                    .textCase(.uppercase)
                    .font(CTFont.bold(13))
                    .foregroundStyle(Color.CT.text)
                    .tracking(4)
            }
        }
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
        VStack(spacing: 12) {
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

            if !viewModel.displayName.isEmpty {
                Text(viewModel.displayName)
                    .font(CTFont.bold(20))
                    .foregroundStyle(Color.CT.text)
            }

            Text(viewModel.username.isEmpty
                 ? DisplayNameGenerator.generate(from: viewModel.userId)
                 : "@\(viewModel.username)")
                .font(CTFont.regular(13))
                .foregroundStyle(Color.CT.textDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(Color.CT.bgMsg)
        .overlay(
            Rectangle()
                .fill(Color.CT.noise)
                .frame(height: 1),
            alignment: .bottom
        )
    }

    // MARK: - Identity Section

    private var identitySection: some View {
        ConstructSection(header: NSLocalizedString("account_information", comment: "")) {
            fieldRow(label: LocalizedStringKey("display_name")) {
                TextField(LocalizedStringKey("display_name"), text: $viewModel.displayName)
                    .font(CTFont.regular(16))
                    .foregroundStyle(Color.CT.text)
                    .onChange(of: viewModel.displayName) { _, newValue in
                        viewModel.saveDisplayName(newValue, authViewModel: authViewModel)
                    }
            }

            ConstructRowDivider(indent: 16)

            fieldRow(label: LocalizedStringKey("username")) {
                HStack {
                    TextField(LocalizedStringKey("username"), text: $viewModel.username)
                        .font(CTFont.regular(15))
                        .foregroundStyle(Color.CT.text)
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
                        .font(CTFont.regular(13))
                        .foregroundStyle(Color.CT.accent)
                    } else if viewModel.usernameSaved {
                        Text(LocalizedStringKey("saved"))
                            .font(CTFont.regular(12))
                            .foregroundStyle(Color.CT.textDim)
                            .transition(.opacity)
                    }
                }
            }

            if let error = viewModel.usernameSaveError {
                Text(error)
                    .font(CTFont.regular(11))
                    .foregroundStyle(Color.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Data & Privacy

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ConstructSection(header: NSLocalizedString("data_and_privacy", comment: "")) {
                ConstructButtonRow(icon: "square.and.arrow.up", title: LocalizedStringKey("export_my_data")) {
                    showingExportAlert = true
                }
            }
            Text(LocalizedStringKey("export_my_data_footer"))
                .font(CTFont.regular(11))
                .foregroundStyle(Color.CT.textDim)
                .padding(.horizontal, 20)
        }
    }

    // MARK: - Danger Zone

    private var dangerSection: some View {
        ConstructSection(header: NSLocalizedString("danger_zone", comment: "")) {
            Button {
                showingDeleteConfirmation = true
            } label: {
                HStack(spacing: 14) {
                    Text(LocalizedStringKey("delete_my_account"))
                        .font(CTFont.bold(16))
                        .foregroundStyle(Color.CT.danger)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 32)
    }

    // MARK: - Layout Helpers

    private func fieldRow<Content: View>(label: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(CTFont.bold(10))
                .foregroundStyle(Color.CT.textDim)
                .tracking(0.8)
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
