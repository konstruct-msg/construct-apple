//
//  AccountSettingsView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 30.12.2025.
//

import SwiftUI
import CoreData

struct AccountSettingsView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @EnvironmentObject var authViewModel: AuthViewModel
    @StateObject private var viewModel = SettingsViewModel()

    @State private var showingImagePicker = false
    @State private var showingAvatarViewer = false
    @State private var showingDeleteConfirmation = false
    @State private var showingExportAlert = false

    var body: some View {
        List {
            // MARK: - Avatar + Identity
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 10) {
                        Group {
                            if let image = viewModel.profileImage {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: AvatarStyle.accountSize, height: AvatarStyle.accountSize)
                                    .clipShape(RoundedRectangle(cornerRadius: AvatarStyle.accountCornerRadius, style: .continuous))
                            } else {
                                RoundedRectangle(cornerRadius: AvatarStyle.accountCornerRadius, style: .continuous)
                                    .fill(Color.blue.opacity(0.2))
                                    .frame(width: AvatarStyle.accountSize, height: AvatarStyle.accountSize)
                                    .overlay {
                                        Text(viewModel.displayName.prefix(1).uppercased())
                                            .font(.system(size: 40, weight: .semibold))
                                            .foregroundColor(.blue)
                                    }
                            }
                        }
                        .onTapGesture {
                            if viewModel.profileImage != nil {
                                showingAvatarViewer = true
                            } else {
                                showingImagePicker = true
                            }
                        }

                        Text(viewModel.username.isEmpty
                             ? DisplayNameGenerator.generate(from: viewModel.userId)
                             : "@\(viewModel.username)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }

            // MARK: - Account Information
            Section {
                TextField("username", text: $viewModel.username)
                    .font(.body.monospaced())
                
                TextField("display_name", text: $viewModel.displayName)
                    .onChange(of: viewModel.displayName) { _, newValue in
                        viewModel.saveDisplayName(newValue, authViewModel: authViewModel)
                    }
            } header: {
                Text("account_information")
            }

            // MARK: - Privacy
            Section {
                Label("privacy_who_can_find_me", systemImage: "person.fill.questionmark")
                    .foregroundColor(.secondary)
                Label("privacy_read_receipts", systemImage: "checkmark.message")
                    .foregroundColor(.secondary)
            } header: {
                Text("privacy")
            } 

            // MARK: - Data & Privacy
            Section {
                Button {
                    showingExportAlert = true
                } label: {
                    Label("export_my_data", systemImage: "square.and.arrow.up")
                }
            } header: {
                Text("data_and_privacy")
            } footer: {
                Text("export_my_data_footer")
            }

            // MARK: - Danger Zone
            Section {
                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Label("delete_my_account", systemImage: "trash")
                }
            } header: {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                    Text("danger_zone")
                        .foregroundColor(.red)
                }
            } footer: {
                Text("delete_account_footer")
            }
        }
        .alert("export_my_data", isPresented: $showingExportAlert) {
            Button("ok", role: .cancel) { }
        } message: {
            Text("export_coming_soon_message")
        }
        .navigationTitle("account")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.setContext(viewContext)
            viewModel.loadUserInfo(from: authViewModel)
        }
        .sheet(isPresented: $showingDeleteConfirmation) {
            DeleteAccountConfirmationView(
                onDelete: {
                    authViewModel.deleteAccount()
                },
                onCancel: {
                    showingDeleteConfirmation = false
                }
            )
            .environmentObject(authViewModel)
        }
        .sheet(isPresented: $showingAvatarViewer) {
            AvatarViewerSheet(
                image: viewModel.profileImage,
                onChangeAvatar: {
                    showingAvatarViewer = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showingImagePicker = true
                    }
                }
            )
        }
        .sheet(isPresented: $showingImagePicker) {
            ImagePicker(onImagePicked: { image in
                viewModel.saveAvatar(image, authViewModel: authViewModel)
            })
        }
    }
}

// MARK: - Delete Account Confirmation View
struct DeleteAccountConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var authViewModel: AuthViewModel

    let onDelete: () -> Void
    let onCancel: () -> Void

    @State private var countdown = 7
    @State private var errorMessage: String?
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

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
            Image(systemName: "person.crop.circle.badge.minus")
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

            // Error message
            if let err = errorMessage {
                Text(err)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
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
        .onReceive(timer) { _ in
            if countdown > 0 { countdown -= 1 }
        }
        .onChange(of: authViewModel.errorMessage) { _, msg in
            if let msg { errorMessage = msg }
        }
        .onChange(of: authViewModel.isLoading) { _, loading in
            // Clear error when new attempt starts
            if loading { errorMessage = nil }
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

// MARK: - Image Picker
struct ImagePicker: UIViewControllerRepresentable {
    let onImagePicked: (UIImage) -> Void
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.allowsEditing = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ImagePicker

        init(_ parent: ImagePicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let editedImage = info[.editedImage] as? UIImage {
                parent.onImagePicked(editedImage)
            } else if let originalImage = info[.originalImage] as? UIImage {
                parent.onImagePicked(originalImage)
            }

            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

//#Preview {
//    let container = PreviewHelpers.createPreviewContainer()
//    let context = container.viewContext
//
//    // Create sample user
//    let user = User(context: context)
//    user.id = "user123"
//    user.username = "john_doe"
//    user.displayName = "John Doe"
//
//    try? context.save()
//
//    let authViewModel = AuthViewModel(context: context)
//    authViewModel.configureMockAuth()
//
//    return NavigationStack {
//        AccountSettingsView()
//            .environment(\.managedObjectContext, context)
//            .environmentObject(authViewModel)
//    }
//}
