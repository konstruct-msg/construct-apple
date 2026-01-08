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
    
    init(viewModel: AuthViewModel) {
        self.viewModel = viewModel
        // Загружаем последний использованный username при инициализации
        if let lastUsername = KeychainManager.shared.loadLastUsername() {
            _username = State(initialValue: lastUsername)
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("username")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                TextField("enter_username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                    .onChange(of: username) { newValue in
                        username = newValue.lowercased()
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("password")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                }
                SecureField("enter_password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
            }
            
            Spacer()

            Button {
                viewModel.login(username: username, password: password)
            } label: {
                Text("login")
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
    let container = PreviewHelpers.createPreviewContainer()
    return LoginView(viewModel: AuthViewModel(context: container.viewContext))
        .padding()
}

