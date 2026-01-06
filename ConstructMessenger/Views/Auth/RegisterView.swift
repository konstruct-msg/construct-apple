//
//  RegisterView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import SwiftUI

struct RegisterView: View {
    @ObservedObject var viewModel: AuthViewModel

    @State private var username = ""
    @State private var displayName = ""
    @State private var password = ""
    @State private var confirmPassword = ""

    private var passwordPlaceholder: String {
        String(format: NSLocalizedString("min_password_placeholder", comment: "Placeholder for password field with minimum length"), ValidationRules.minPasswordLength)
    }

    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("username")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("*")
                        .font(.caption)
                        .foregroundColor(.red)
                }
                TextField("enter_username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .onChange(of: username) { newValue in
                        username = newValue.lowercased()
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("password")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("*")
                        .font(.caption)
                        .foregroundColor(.red)
                }
                SecureField(passwordPlaceholder, text: $password)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("confirm_password")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("*")
                        .font(.caption)
                        .foregroundColor(.red)
                }
                SecureField("reenter_password", text: $confirmPassword)
                    .textFieldStyle(.roundedBorder)
            }
            
            Spacer()

            Button {
                viewModel.register(
                    username: username,
                    displayName: displayName.isEmpty ? username : displayName,
                    password: password
                )
            } label: {
                Text("register")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(isValid ? Color.blue : Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            .disabled(!isValid || viewModel.isLoading)

        }
    }

    private var isValid: Bool {
        !username.isEmpty &&
        !password.isEmpty &&
        password == confirmPassword &&
        password.count >= ValidationRules.minPasswordLength
    }
}

#Preview {
    let container = PreviewHelpers.createPreviewContainer()
    return RegisterView(viewModel: AuthViewModel(context: container.viewContext))
        .padding()
}

