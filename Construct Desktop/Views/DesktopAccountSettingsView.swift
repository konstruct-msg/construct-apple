//
//  DesktopAccountSettingsView.swift
//  Construct Desktop
//
//  Lightweight macOS-friendly account settings UI.
//

import SwiftUI

struct DesktopAccountSettingsView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(AuthViewModel.self) private var authViewModel

    @State private var viewModel = SettingsViewModel()
    @State private var originalUsername: String = ""

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("User ID") {
                Text(viewModel.userId.isEmpty ? "—" : viewModel.userId)
                    .font(DesktopTheme.monoFont(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Divider()

            LabeledContent("Display Name") {
                TextField("Display Name", text: $viewModel.displayName)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: viewModel.displayName) { _, newValue in
                        viewModel.saveDisplayName(newValue, authViewModel: authViewModel)
                    }
            }

            LabeledContent("Username") {
                HStack(spacing: 8) {
                    TextField("Username", text: $viewModel.username)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit { Task { await saveUsernameIfNeeded() } }

                    if viewModel.isSavingUsername {
                        ProgressView().scaleEffect(0.8)
                    } else if viewModel.username != originalUsername {
                        Button("Save") { Task { await saveUsernameIfNeeded() } }
                    } else if viewModel.usernameSaved {
                        Text("Saved")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let error = viewModel.usernameSaveError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
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
    }

    private func saveUsernameIfNeeded() async {
        await viewModel.saveUsername(viewModel.username, authViewModel: authViewModel)
    }
}

#Preview {
    DesktopAccountSettingsView()
        .environment(AuthViewModel(context: PersistenceController.shared.container.viewContext))
        .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
        .padding()
        .frame(width: 500)
}
