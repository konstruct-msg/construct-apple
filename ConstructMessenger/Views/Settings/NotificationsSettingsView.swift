//
//  NotificationsSettingsView.swift
//  ConstructMessenger
//
//  Created by Maxim Eliseyev on 02.01.2026.
//

import SwiftUI
import UserNotifications

struct NotificationsSettingsView: View {
    // MARK: - Notification Settings
    @AppStorage("notificationsEnabled") private var notificationsEnabled: Bool = true
    @AppStorage("showMessageNotifications") private var showMessageNotifications: Bool = true
    @AppStorage("notificationPreviewType") private var notificationPreviewType: NotificationPreviewType = .nameAndMessage
    @AppStorage("notificationSound") private var notificationSound: Bool = true
    @AppStorage("notificationVibration") private var notificationVibration: Bool = true
    @AppStorage("pushNotificationsEnabled") private var pushNotificationsEnabled: Bool = false

    // MARK: - State
    @State private var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @State private var showingSystemSettings = false

    var body: some View {
        List {
            // MARK: - General Notifications
            Section {
                Toggle(isOn: $notificationsEnabled) {
                    Label {
                        Text("enable_notifications")
                    } icon: {
                        Image(systemName: notificationsEnabled ? "bell.fill" : "bell.slash.fill")
                            .foregroundColor(notificationsEnabled ? Color.AppBrand.second : .gray)
                    }
                }
            } footer: {
                Text("notifications_footer")
                    .font(.caption)
            }

            // MARK: - System Permission Status
            Section {
                HStack {
                    Label {
                        Text("status")
                    } icon: {
                        Image(systemName: statusIcon)
                            .foregroundColor(statusColor)
                    }

                    Spacer()

                    Text(statusText)
                        .foregroundColor(.secondary)
                }

                if authorizationStatus == .denied {
                    Button {
                        openSystemSettings()
                    } label: {
                        Label {
                            Text("open_system_settings")
                                .foregroundColor(.primary)
                        } icon: {
                            Image(systemName: "gear")
                                .foregroundColor(.orange)
                        }
                    }
                } else if authorizationStatus == .notDetermined {
                    Button {
                        requestNotificationPermission()
                    } label: {
                        Label {
                            Text("grant_permission")
                                .foregroundColor(.primary)
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(Color.AppStatus.success)
                        }
                    }
                }
            } header: {
                Text("system_notification_settings")
            } footer: {
                if authorizationStatus == .denied {
                    Text("notification_permissions_required")
                        .font(.caption)
                        .foregroundColor(.orange)
                } else {
                    Text("system_settings_footer")
                        .font(.caption)
                }
            }

            // MARK: - Message Notifications
            if notificationsEnabled {
                Section {
                    Toggle(isOn: $showMessageNotifications) {
                        Label {
                            Text("show_message_notifications")
                        } icon: {
                            Image(systemName: "message.fill")
                                .foregroundColor(Color.AppStatus.success)
                        }
                    }

                    // MARK: - Sound & Haptics
                    Section {
                        Toggle(isOn: $notificationSound) {
                            Label {
                                Text("notification_sound")
                            } icon: {
                                Image(systemName: notificationSound ? "speaker.wave.2.fill" : "speaker.slash.fill")
                                    .foregroundColor(notificationSound ? Color.AppBrand.second : .gray)
                            }
                        }

                        Toggle(isOn: $notificationVibration) {
                            Label {
                                Text("vibration")
                            } icon: {
                                Image(systemName: "iphone.radiowaves.left.and.right")
                                    .foregroundColor(notificationVibration ? .purple : .gray)
                            }
                        }
                    }
                }

                // MARK: - Push Notifications
                Section {
                    Toggle(isOn: $pushNotificationsEnabled) {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("enable_push_notifications")
                                Text("push_notifications_footer")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "bell.badge.fill")
                                .foregroundColor(pushNotificationsEnabled ? .orange : .gray)
                        }
                    }
                    .disabled(authorizationStatus != .authorized)

                    // Privacy Notice
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundColor(Color.AppStatus.success)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("push_privacy_notice")
                                .font(.subheadline)
                                .fontWeight(.medium)

                            Text("push_privacy_notice_text")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("push_notifications")
                }
            }
        }
        .navigationTitle("notifications")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            checkNotificationAuthorization()
        }
    }

    // MARK: - Computed Properties
    private var statusIcon: String {
        switch authorizationStatus {
        case .authorized:
            return "checkmark.circle.fill"
        case .denied:
            return "xmark.circle.fill"
        case .notDetermined:
            return "questionmark.circle.fill"
        case .provisional:
            return "checkmark.circle"
        case .ephemeral:
            return "checkmark.circle"
        @unknown default:
            return "questionmark.circle"
        }
    }

    private var statusColor: Color {
        switch authorizationStatus {
        case .authorized:
            return Color.AppStatus.success
        case .denied:
            return .red
        case .notDetermined:
            return .orange
        case .provisional:
            return Color.AppBrand.second
        case .ephemeral:
            return Color.AppBrand.second
        @unknown default:
            return .gray
        }
    }

    private var statusText: LocalizedStringKey {
        switch authorizationStatus {
        case .authorized:
            return "authorized"
        case .denied:
            return "denied"
        case .notDetermined:
            return "not_determined"
        case .provisional:
            return "authorized"
        case .ephemeral:
            return "authorized"
        @unknown default:
            return "unknown"
        }
    }

    // MARK: - Methods
    private func checkNotificationAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                authorizationStatus = settings.authorizationStatus
            }
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            DispatchQueue.main.async {
                checkNotificationAuthorization()
                if granted {
                    notificationsEnabled = true
                }
            }
        }
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Notification Preview Type
enum NotificationPreviewType: String, CaseIterable {
    case nameAndMessage
    case nameOnly
    case none

    var displayName: LocalizedStringKey {
        switch self {
        case .nameAndMessage: return "preview_name_and_message"
        case .nameOnly: return "preview_name_only"
        case .none: return "preview_none"
        }
    }

    var description: String {
        switch self {
        case .nameAndMessage: return "Show sender name and message content"
        case .nameOnly: return "Show only sender name"
        case .none: return "Show only 'New Message'"
        }
    }

    var iconName: String {
        switch self {
        case .nameAndMessage: return "text.bubble.fill"
        case .nameOnly: return "person.fill"
        case .none: return "eye.slash.fill"
        }
    }
}

// MARK: - Preview
#Preview {
    NavigationStack {
        NotificationsSettingsView()
    }
}
