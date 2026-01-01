//
//  SettingsView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 14.12.2025.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var authViewModel: AuthViewModel
    @StateObject private var viewModel = SettingsViewModel()
    @State private var showingLogoutConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                // MARK: - Account Section
                Section {
                    NavigationLink(destination: AccountSettingsView().environmentObject(authViewModel)) {
                        Label {
                            Text("Account")
                        } icon: {
                            Image(systemName: "person.circle")
                                .foregroundColor(.blue)
                        }
                    }
                } header: {
                    Text("User")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("@\(viewModel.username)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // MARK: - Network Section
                Section {
                    NavigationLink(destination: NetworkSettingsView()) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Network")
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(WebSocketManager.shared.isConnected ? Color.green : Color.red)
                                        .frame(width: 6, height: 6)
                                    Text(WebSocketManager.shared.isConnected ? "Connected" : "Disconnected")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: "network")
                                .foregroundColor(.green)
                        }
                    }
                } header: {
                    Text("Connection")
                }

                // MARK: - Appearance Section
                Section {
                    NavigationLink(destination: AppearanceSettingsView()) {
                        Label {
                            Text("Appearance")
                        } icon: {
                            Image(systemName: "paintbrush.fill")
                                .foregroundColor(.purple)
                        }
                    }
                } header: {
                    Text("Preferences")
                }

                // MARK: - About Section
                Section {
                    HStack {
                        Label {
                            Text("Version")
                        } icon: {
                            Image(systemName: "info.circle")
                                .foregroundColor(.orange)
                        }
                        Spacer()
                        Text("\(AppConstants.appVersion) (\(AppConstants.buildNumber))")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("About")
                }

                // MARK: - Logout Section
                Section {
                    Button(role: .destructive) {
                        showingLogoutConfirmation = true
                    } label: {
                        HStack {
                            Spacer()
                            Label {
                                Text("Logout")
                                    .fontWeight(.semibold)
                            } icon: {
                                Image(systemName: "rectangle.portrait.and.arrow.right")
                            }
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                viewModel.loadUserInfo(from: authViewModel)
            }
            .alert("Logout", isPresented: $showingLogoutConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Logout", role: .destructive) {
                    authViewModel.logout()
                }
            } message: {
                Text("Are you sure you want to logout?")
            }
        }
    }
}

#Preview {
    let authViewModel = AuthViewModel()
    authViewModel.isAuthenticated = true
    authViewModel.currentUserId = "user123"
    authViewModel.currentUsername = "john_doe"
    authViewModel.currentDisplayName = "John Doe"

    return SettingsView()
        .environmentObject(authViewModel)
}
