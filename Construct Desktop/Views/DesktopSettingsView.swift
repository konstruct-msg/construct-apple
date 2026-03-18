//
//  DesktopSettingsView.swift
//  Construct Desktop
//
//  macOS Settings window (Cmd+,).
//

import SwiftUI

struct DesktopSettingsView: View {
    var body: some View {
        TabView {
            DesktopGeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")

            DesktopDevicesSettingsTab()
                .tabItem { Label("Devices", systemImage: "laptopcomputer.and.iphone") }
                .tag("devices")

            DesktopSecuritySettingsTab()
                .tabItem { Label("Security", systemImage: "lock.shield") }
                .tag("security")

            DesktopNotificationsSettingsTab()
                .tabItem { Label("Notifications", systemImage: "bell") }
                .tag("notifications")

            DesktopNetworkSettingsTab()
                .tabItem { Label("Network", systemImage: "network") }
                .tag("network")
        }
        .frame(width: 560, height: 420)
    }
}

// MARK: - General

private struct DesktopGeneralSettingsTab: View {
    @AppStorage("appTheme") private var appTheme: AppTheme = .automatic

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appTheme) {
                    Text("System").tag(AppTheme.automatic)
                    Text("Light").tag(AppTheme.light)
                    Text("Dark").tag(AppTheme.dark)
                }
                .pickerStyle(.radioGroup)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Devices

private struct DesktopDevicesSettingsTab: View {
    @Environment(AuthViewModel.self) private var authViewModel
    @State private var showSignOutConfirm = false
    @State private var showSignOutAllConfirm = false
    @State private var showingLinkSheet = false

    var body: some View {
        Form {
            Section("Linked Devices") {
                // Shows the real DevicesView embedded in a ScrollView-free context
                Button {
                    showingLinkSheet = true
                } label: {
                    Label("Link New Device (Show QR)", systemImage: "plus.circle.fill")
                }
            }

            Section {
                Button(role: .destructive) {
                    showSignOutConfirm = true
                } label: {
                    Text("Sign Out This Device")
                }
                Button(role: .destructive) {
                    showSignOutAllConfirm = true
                } label: {
                    Text("Sign Out All Devices")
                }
            } header: {
                Text("Session")
            } footer: {
                Text("Signing out of all devices immediately invalidates every session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $showingLinkSheet) { DeviceLinkQRSheet() }
        .confirmationDialog(
            "Sign Out This Device",
            isPresented: $showSignOutConfirm,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) { authViewModel.logout() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will be signed out on this Mac only.")
        }
        .confirmationDialog(
            "Sign Out All Devices",
            isPresented: $showSignOutAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Sign Out All", role: .destructive) { authViewModel.logoutAllDevices() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All devices will be signed out immediately. Use this if a device was lost or compromised.")
        }
    }
}

// MARK: - Security

private struct DesktopSecuritySettingsTab: View {
    var body: some View {
        Text("Security settings coming soon")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Notifications

private struct DesktopNotificationsSettingsTab: View {
    var body: some View {
        Text("Notification settings coming soon")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Network

private struct DesktopNetworkSettingsTab: View {
    var body: some View {
        NetworkSettingsView()
    }
}

#Preview {
    DesktopSettingsView()
        .environment(AuthViewModel(context: PersistenceController.shared.container.viewContext))
}
