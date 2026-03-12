//
//  DesktopSettingsView.swift
//  Construct Desktop
//
//  macOS Settings window (⌘,).
//  Uses TabView with SF Symbol icons — standard macOS settings pattern.
//  Each tab will eventually host the shared iOS settings views.
//

import SwiftUI

struct DesktopSettingsView: View {
    var body: some View {
        TabView {
            DesktopGeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")

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
        .frame(width: 500, height: 360)
    }
}

// MARK: - Tab placeholders (replace with shared iOS settings views)

private struct DesktopGeneralSettingsTab: View {
    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: .constant("automatic")) {
                    Text("System").tag("automatic")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.radioGroup)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct DesktopSecuritySettingsTab: View {
    var body: some View {
        Text("Security settings coming soon")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(.secondary)
    }
}

private struct DesktopNotificationsSettingsTab: View {
    var body: some View {
        Text("Notification settings coming soon")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(.secondary)
    }
}

private struct DesktopNetworkSettingsTab: View {
    var body: some View {
        Text("Network settings (ICE proxy) coming soon")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(.secondary)
    }
}

#Preview {
    DesktopSettingsView()
}
