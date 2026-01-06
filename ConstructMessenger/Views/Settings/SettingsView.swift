//
//  SettingsView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 14.12.2025.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @EnvironmentObject var authViewModel: AuthViewModel
    @StateObject private var viewModel = SettingsViewModel()
    @State private var showingQRCode = false
    @State private var linkCopied = false

    var body: some View {
        NavigationStack {
            List {
                // MARK: - Account Section
                Section {
                    NavigationLink(destination: AccountSettingsView().environmentObject(authViewModel)) {
                        Label {
                            Text("account")
                        } icon: {
                            Image(systemName: "person.circle")
                                .foregroundColor(.blue)
                        }
                    }
                } header: {
                    Text("user")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("@\(viewModel.username)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // TODO: Add Security Section here
                // - PIN code protection (6-10 digits)
                // - Biometric authentication (Face ID / Touch ID)
                // - Auto-lock timeout settings
                // See: TODO.md for detailed requirements

                // MARK: - Share Contact Section
                Section {
                    Button {
                        showingQRCode = true
                    } label: {
                        Label {
                            Text("show_my_qr_code")
                                .foregroundColor(.primary)
                        } icon: {
                            Image(systemName: "qrcode")
                                .foregroundColor(.blue)
                        }
                    }

                    Button {
                        copyContactLink()
                    } label: {
                        Label {
                            Text(linkCopied ? "link_copied" : "copy_contact_link")
                                .foregroundColor(.primary)
                        } icon: {
                            Image(systemName: linkCopied ? "checkmark.circle.fill" : "link")
                                .foregroundColor(linkCopied ? .green : .green)
                        }
                    }
                    .disabled(linkCopied)
                } header: {
                    Text("share_contact")
                }

                // MARK: - Preferences Section
                Section {
                    NavigationLink(destination: NetworkSettingsView()) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("network")
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(WebSocketManager.shared.isConnected ? Color.green : Color.red)
                                        .frame(width: 6, height: 6)
                                    Text(WebSocketManager.shared.isConnected ? "connected" : "disconnected")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: "network")
                                .foregroundColor(.green)
                        }
                    }
                    NavigationLink(destination: AppearanceSettingsView()) {
                        Label {
                            Text("appearance")
                        } icon: {
                            Image(systemName: "paintbrush.fill")
                                .foregroundColor(.purple)
                        }
                    }
                    NavigationLink(destination: NotificationsSettingsView()) {
                        Label {
                            Text("notifications")
                        } icon: {
                            Image(systemName: "bell")
                                .foregroundColor(.blue)
                        }
                    }
                } header: {
                    Text("preferences")
                }

                // MARK: - About Section
                Section {
                    HStack {
                        Label {
                            Text("version")
                        } icon: {
                            Image(systemName: "info.circle")
                                .foregroundColor(.orange)
                        }
                        Spacer()
                        Text("Construct v\(AppConstants.appVersion)")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("about")
                }
            }
            .navigationTitle("settings")
            .onAppear {
                viewModel.setContext(viewContext)
                viewModel.loadUserInfo(from: authViewModel)
            }
            .sheet(isPresented: $showingQRCode) {
                ContactQRCodeView(
                    userId: viewModel.userId,
                    username: viewModel.username
                )
            }
        }
    }

    // MARK: - Contact Link
    private var contactLink: String {
        guard let userId = authViewModel.currentUserId,
              let username = authViewModel.currentUsername else {
            return ""
        }
        return "construct://add-contact?id=\(userId)&username=\(username)"
    }

    private func copyContactLink() {
        UIPasteboard.general.string = contactLink
        print("Contact link copied: \(contactLink)")

        // Show visual feedback
        withAnimation {
            linkCopied = true
        }

        // Reset after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                linkCopied = false
            }
        }
    }
}

#Preview {
    let container = PreviewHelpers.createPreviewContainer()
    let authViewModel = AuthViewModel(context: container.viewContext)
    authViewModel.isAuthenticated = true
    authViewModel.currentUserId = "user123"
    authViewModel.currentUsername = "john_doe"
    authViewModel.currentDisplayName = "John Doe"

    return SettingsView()
        .environmentObject(authViewModel)
}
