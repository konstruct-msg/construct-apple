//
//  DesktopSettingsView.swift
//  Construct Desktop
//
//  macOS Settings window (Cmd+,).
//

import SwiftUI
import UserNotifications

struct DesktopSettingsView: View {
    var body: some View {
        TabView {
            DesktopAccountSettingsTab()
                .tabItem { Label("Account", systemImage: "person.circle") }
                .tag("account")

            DesktopGeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")

            DesktopSecuritySettingsTab()
                .tabItem { Label("Security", systemImage: "lock.shield") }
                .tag("security")

            DesktopNotificationsSettingsTab()
                .tabItem { Label("Notifications", systemImage: "bell") }
                .tag("notifications")

            DesktopStorageSettingsTab()
                .tabItem { Label("Storage", systemImage: "internaldrive") }
                .tag("storage")

            DesktopNetworkSettingsTab()
                .tabItem { Label("Network", systemImage: "network") }
                .tag("network")

            DesktopDiagnosticsSettingsTab()
                .tabItem { Label("Diagnostics", systemImage: "waveform.path.ecg") }
                .tag("diagnostics")
        }
        .frame(width: 580, height: 460)
    }
}

// MARK: - Account

private struct DesktopAccountSettingsTab: View {
    @Environment(AuthViewModel.self) private var authViewModel
    @Environment(SecurityViewModel.self) private var securityViewModel
    @Environment(AccountRecoveryViewModel.self) private var recoveryViewModel
    @Environment(\.managedObjectContext) private var viewContext
    @State private var showSignOutConfirm = false

    var body: some View {
        Form {
            Section("Profile") {
                DesktopAccountSettingsView()
            }
            Section {
                Button(role: .destructive) {
                    showSignOutConfirm = true
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        .foregroundStyle(DesktopTheme.destructive)
                }
            } header: {
                Text("Session")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Sign Out", isPresented: $showSignOutConfirm, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { authViewModel.logout() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will be signed out on this Mac only.")
        }
    }
}

// MARK: - General

private struct DesktopGeneralSettingsTab: View {
    @AppStorage("appTheme") private var appTheme: AppTheme = .automatic
    @AppStorage("desktopSendOnEnter") private var sendOnEnter: Bool = true
    @AppStorage("desktopShowTimestamps") private var showTimestamps: Bool = true

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

            Section("Composing") {
                Toggle("Send with ⏎  (Shift+⏎ for new line)", isOn: $sendOnEnter)
            }

            Section("Messages") {
                Toggle("Show timestamps on every message", isOn: $showTimestamps)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Security

private struct DesktopSecuritySettingsTab: View {
    @Environment(SecurityViewModel.self) private var securityViewModel
    @Environment(AuthViewModel.self) private var authViewModel

    var body: some View {
        Form {
            Section("End-to-End Encryption") {
                labelRow("Protocol", value: "Double Ratchet + Kyber-1024 (PQC)")
                labelRow("Forward Secrecy", value: "Per-message ratchet")
                labelRow("Key Agreement", value: "PQXDH (X25519 + Kyber KEM)")
            }

            Section("Session Keys") {
                DesktopSecurityView()
            }
        }
        .formStyle(.grouped)
    }

    private func labelRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(DesktopTheme.textSecondary)
            Spacer()
            Text(value)
                .font(DesktopTheme.monoFont(11))
                .foregroundStyle(DesktopTheme.textTertiary)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Notifications

private struct DesktopNotificationsSettingsTab: View {
    @State private var authStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        Form {
            Section("System Notifications") {
                HStack {
                    Text("Permission")
                    Spacer()
                    statusBadge
                }

                if authStatus == .denied {
                    Button("Open System Settings…") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
                        )
                    }
                } else if authStatus == .notDetermined {
                    Button("Request Permission") {
                        Task {
                            _ = try? await UNUserNotificationCenter.current()
                                .requestAuthorization(options: [.alert, .sound, .badge])
                            await refreshStatus()
                        }
                    }
                }
            }
            .task { await refreshStatus() }

            Section("Delivery") {
                NotificationsSettingsView()
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var statusBadge: some View {
        switch authStatus {
        case .authorized, .provisional:
            Label("Enabled", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .denied:
            Label("Denied", systemImage: "xmark.circle.fill").foregroundStyle(DesktopTheme.destructive)
        default:
            Label("Not set", systemImage: "questionmark.circle").foregroundStyle(.secondary)
        }
    }

    private func refreshStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        await MainActor.run { authStatus = settings.authorizationStatus }
    }
}

// MARK: - Storage

private struct DesktopStorageSettingsTab: View {
    var body: some View {
        Form {
            Section("Media Cache") {
                DataStorageSettingsView()
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Network

private struct DesktopNetworkSettingsTab: View {
    var body: some View {
        NetworkSettingsView()
    }
}

// MARK: - Diagnostics

private struct DesktopDiagnosticsSettingsTab: View {
    var body: some View {
        DiagnosticsView()
    }
}

#Preview {
    DesktopSettingsView()
        .environment(AuthViewModel(context: PersistenceController.shared.container.viewContext))
        .environment(SecurityViewModel())
        .environment(AccountRecoveryViewModel())
}

#Preview {
    DesktopSettingsView()
        .environment(AuthViewModel(context: PersistenceController.shared.container.viewContext))
        .environment(SecurityViewModel())
        .environment(AccountRecoveryViewModel())
}
