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

    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Username")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("*")
                        .font(.caption)
                        .foregroundColor(.red)
                }
                TextField("Enter username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .onChange(of: username) { newValue in
                        username = newValue.lowercased()
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Password")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("*")
                        .font(.caption)
                        .foregroundColor(.red)
                }
                SecureField("Min \(ValidationRules.minPasswordLength) characters", text: $password)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Confirm Password")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("*")
                        .font(.caption)
                        .foregroundColor(.red)
                }
                SecureField("Re-enter password", text: $confirmPassword)
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
                Text("Register")
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
    RegisterView(viewModel: AuthViewModel())
        .padding()
}

