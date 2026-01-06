//
//  AccountSettingsView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 30.12.2025.
//

import SwiftUI

struct AccountSettingsView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @EnvironmentObject var authViewModel: AuthViewModel
    @StateObject private var viewModel = SettingsViewModel()

    // Profile Picture
    @State private var showingImagePicker = false

    // Change Password
    @State private var showingChangePassword = false
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var passwordError: String?
    
    @State private var showingLogoutConfirmation = false

    private var passwordFooterText: Text {
        Text(String(format: NSLocalizedString("password_min_length_message", comment: ""), ValidationRules.minPasswordLength))
    }

    var body: some View {
        List {
            // MARK: - Profile Picture Section
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        if let image = viewModel.profileImage {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 100, height: 100)
                                .clipShape(Circle())
                        } else {
                            Circle()
                                .fill(Color.blue.opacity(0.2))
                                .frame(width: 100, height: 100)
                                .overlay {
                                    Text(viewModel.displayName.prefix(1).uppercased())
                                        .font(.system(size: 40, weight: .semibold))
                                        .foregroundColor(.blue)
                                }
                        }
                    }
                    .onTapGesture {
                        showingImagePicker = true
                    }
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }
            
            Text("@\(viewModel.username)")
                .fontWeight(.medium)
                .foregroundColor(.gray)

            // MARK: - Account Information Section
            Section {
                TextField("display_name", text: $viewModel.displayName)
                    .onChange(of: viewModel.displayName) { newValue in
                        viewModel.saveDisplayName(newValue, authViewModel: authViewModel)
                    }

            } header: {
                Text("account_information")
            }

            // MARK: - Password Section
            Section {
                if showingChangePassword {
                    SecureField("current_password", text: $currentPassword)
                        .textContentType(.password)

                    SecureField("new_password", text: $newPassword)
                        .textContentType(.newPassword)

                    SecureField("confirm_new_password", text: $confirmPassword)
                        .textContentType(.newPassword)

                    if let error = passwordError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    HStack {
                        Button("cancel") {
                            cancelPasswordChange()
                        }

                        Spacer()

                        Button("change_password") {
                            changePassword()
                        }
                        .disabled(!isPasswordValid)
                    }
                } else {
                    Button {
                        showingChangePassword = true
                    } label: {
                        Text("change_password")
                    }
                }
            } header: {
                Text("security")
            } footer: {
                if showingChangePassword {
                    passwordFooterText
                        .font(.caption)
                }
            }
            
            // MARK: - Logout Section
            Section {
                Button(role: .destructive) {
                    showingLogoutConfirmation = true
                } label: {
                    HStack {
                        Spacer()
                        Label {
                            Text("logout")
                                .fontWeight(.semibold)
                        } icon: {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                        }
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle("account")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.setContext(viewContext)
            viewModel.loadUserInfo(from: authViewModel)
        }
        .alert("logout", isPresented: $showingLogoutConfirmation) {
            Button("cancel", role: .cancel) { }
            Button("logout", role: .destructive) {
                authViewModel.logout()
            }
        } message: {
            Text("logout_confirmation")
        }
        .sheet(isPresented: $showingImagePicker) {
            ImagePicker(onImagePicked: { image in
                viewModel.saveAvatar(image, authViewModel: authViewModel)
            })
        }
    }

    // MARK: - Validation
    private var isPasswordValid: Bool {
        !currentPassword.isEmpty &&
        !newPassword.isEmpty &&
        newPassword == confirmPassword &&
        newPassword.count >= ValidationRules.minPasswordLength
    }

    // MARK: - Actions
    private func changePassword() {
        guard isPasswordValid else {
            passwordError = NSLocalizedString("please_check_all_fields", comment: "")
            return
        }

        // TODO: Implement password change API call
        // For now, just clear the form
        print("Changing password for user: \(viewModel.username)")
        cancelPasswordChange()
    }

    private func cancelPasswordChange() {
        showingChangePassword = false
        currentPassword = ""
        newPassword = ""
        confirmPassword = ""
        passwordError = nil
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
    authViewModel.isAuthenticated = true
    authViewModel.currentUserId = "user123"
    authViewModel.currentUsername = "john_doe"
    authViewModel.currentDisplayName = "John Doe"

    return NavigationStack {
        AccountSettingsView()
            .environment(\.managedObjectContext, context)
            .environmentObject(authViewModel)
    }
}
