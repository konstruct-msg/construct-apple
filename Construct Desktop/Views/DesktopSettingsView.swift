//
//  DesktopSettingsView.swift
//  Construct Desktop
//
//  CT-terminal-style Settings window (⌘,).
//  Sidebar list of ASCII-labelled sections + content pane.
//

import SwiftUI
import UserNotifications

struct DesktopSettingsView: View {

    enum Section: String, CaseIterable, Identifiable {
        case account      = "> IDENTITY"
        case general      = "> GENERAL"
        case security     = "> SECURITY"
        case notifications = "> NOTIFICATIONS"
        case storage      = "> STORAGE"
        case network      = "> NETWORK"
        case diagnostics  = "> DIAGNOSTICS"

        var id: String { rawValue }
    }

    @State private var selected: Section = .account

    var body: some View {
        HStack(spacing: 0) {
            // MARK: Sidebar
            VStack(alignment: .leading, spacing: 0) {
                Text("> SETTINGS")
                    .font(CTFont.bold(11))
                    .foregroundStyle(Color.CT.accent)
                    .tracking(3)
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 14)

                Rectangle()
                    .fill(Color.CT.noise)
                    .frame(height: 1)
                    .padding(.bottom, 6)

                ForEach(Section.allCases) { section in
                    sidebarRow(section)
                }

                Spacer()
            }
            .frame(width: 180)
            .ctBackground()

            // Separator
            Rectangle()
                .fill(Color.CT.noise)
                .frame(width: 1)

            // MARK: Content pane
            Group {
                switch selected {
                case .account:       DesktopAccountSettingsTab()
                case .general:       DesktopGeneralSettingsTab()
                case .security:      DesktopSecuritySettingsTab()
                case .notifications: DesktopNotificationsSettingsTab()
                case .storage:       DesktopStorageSettingsTab()
                case .network:       DesktopNetworkSettingsTab()
                case .diagnostics:   DesktopDiagnosticsSettingsTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ctBackground()
        }
        .frame(width: 660, height: 500)
    }

    private func sidebarRow(_ section: Section) -> some View {
        let isActive = selected == section
        return Button {
            selected = section
        } label: {
            HStack(spacing: 8) {
                if isActive {
                    Rectangle()
                        .fill(Color.CT.accent)
                        .frame(width: 2, height: 14)
                }
                Text(section.rawValue)
                    .font(CTFont.regular(12))
                    .foregroundStyle(isActive ? Color.CT.accent : Color.CT.textDim)
                    .tracking(isActive ? 1 : 0)
                Spacer()
            }
            .padding(.leading, isActive ? 12 : 16)
            .padding(.vertical, 8)
            .background(isActive ? Color.CT.accent.opacity(0.07) : Color.clear)
        }
        .buttonStyle(.plain)
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
                    Text("[→] SIGN OUT")
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
            Text("[✓] ENABLED").font(CTFont.regular(12)).foregroundStyle(Color.CT.accent)
        case .denied:
            Text("[✗] DENIED").font(CTFont.regular(12)).foregroundStyle(Color.CT.danger)
        default:
            Text("[?] NOT SET").font(CTFont.regular(12)).foregroundStyle(Color.CT.textDim)
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
