//
//  LoginView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import SwiftUI

struct LoginView: View {
    @ObservedObject var viewModel: AuthViewModel

    @State private var username = ""
    @State private var password = ""

    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Username")
                        .font(.caption)
                        .foregroundColor(.secondary)
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
                    
                }
                SecureField("Enter password", text: $password)
                    .textFieldStyle(.roundedBorder)
            }
            
            Spacer()

            Button {
                viewModel.login(username: username, password: password)
            } label: {
                Text("Login")
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
        !username.isEmpty && !password.isEmpty
    }
}

#Preview {
    LoginView(viewModel: AuthViewModel())
        .padding()
}

