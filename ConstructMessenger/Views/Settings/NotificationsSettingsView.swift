//
//  NotificationsSettingsView.swift
//  ConstructMessenger
//
//  Created by Maxim Eliseyev on 02.01.2026.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import UserNotifications

struct NotificationsSettingsView: View {
    // MARK: - Notification Settings
    @Environment(\.dismiss) private var dismiss
    @AppStorage("notificationsEnabled") private var notificationsEnabled: Bool = true
    @AppStorage("showMessageNotifications") private var showMessageNotifications: Bool = true
    @AppStorage("notificationPreviewType") private var notificationPreviewType: NotificationPreviewType = .nameAndMessage
    @AppStorage("notificationSound") private var notificationSound: Bool = true
    @AppStorage("notificationVibration") private var notificationVibration: Bool = true
    @AppStorage("pushNotificationsEnabled") private var pushNotificationsEnabled: Bool = true

    // MARK: - State
    @State private var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @State private var showingSystemSettings = false

    var body: some View {
        VStack(spacing: 0) {
            CTNavBar(
                title: NSLocalizedString("notifications", comment: ""),
                showBack: true,
                backAction: { dismiss() }
            )
            ScrollView {
            VStack(spacing: 0) {

                // MARK: - General Notifications
                CTSettingsSectionHeader(title: NSLocalizedString("notifications", comment: "").uppercased())
                HStack {
                    Text(LocalizedStringKey("enable_notifications"))
                        .font(CTFont.regular(13))
                        .foregroundColor(Color.CT.textDim)
                    Spacer()
                    Toggle("", isOn: $notificationsEnabled)
                        .labelsHidden()
                        .tint(Color.CT.accent)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                Text(LocalizedStringKey("notifications_footer"))
                    .font(CTFont.regular(11))
                    .foregroundStyle(Color.CT.textDim)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                CTSep()

                // MARK: - System Permission Status
                CTSettingsSectionHeader(title: NSLocalizedString("system_notification_settings", comment: "").uppercased())
                HStack {
                    Text(LocalizedStringKey("status"))
                        .font(CTFont.regular(13))
                        .foregroundColor(Color.CT.textDim)
                    Spacer()
                    Text(statusText)
                        .font(CTFont.regular(13))
                        .foregroundColor(statusColor)
                    Text(statusIcon)
                        .font(CTFont.regular(13))
                        .foregroundColor(statusColor)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)

                if authorizationStatus == .denied {
                    CTSep(style: .thin)
                    Button(action: openSystemSettings) {
                        HStack {
                            Text(LocalizedStringKey("open_system_settings"))
                                .font(CTFont.regular(13))
                                .foregroundColor(Color.CT.textDim)
                            Spacer()
                            Text("[→]")
                                .font(CTFont.regular(13))
                                .foregroundColor(Color.CT.accent)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else if authorizationStatus == .notDetermined {
                    CTSep(style: .thin)
                    Button(action: requestNotificationPermission) {
                        HStack {
                            Text(LocalizedStringKey("grant_permission"))
                                .font(CTFont.regular(13))
                                .foregroundColor(Color.CT.accent)
                            Spacer()
                            Text("[→]")
                                .font(CTFont.regular(13))
                                .foregroundColor(Color.CT.accent)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if authorizationStatus == .denied {
                    Text(LocalizedStringKey("notification_permissions_required"))
                        .font(CTFont.regular(11))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                } else {
                    Text(LocalizedStringKey("system_settings_footer"))
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.textDim)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
                CTSep()

                // MARK: - Message Notifications
                if notificationsEnabled {
                    CTSettingsSectionHeader(title: NSLocalizedString("MESSAGE_NOTIFICATIONS", comment: "").uppercased())
                    HStack {
                        Text(LocalizedStringKey("show_message_notifications"))
                            .font(CTFont.regular(13))
                            .foregroundColor(Color.CT.textDim)
                        Spacer()
                        Toggle("", isOn: $showMessageNotifications)
                            .labelsHidden()
                            .tint(Color.CT.accent)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)

                    CTSep(style: .thin)

                    HStack {
                        Text(LocalizedStringKey("notification_sound"))
                            .font(CTFont.regular(13))
                            .foregroundColor(Color.CT.textDim)
                        Spacer()
                        Toggle("", isOn: $notificationSound)
                            .labelsHidden()
                            .tint(Color.CT.accent)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)

                    CTSep(style: .thin)

                    HStack {
                        Text(LocalizedStringKey("vibration"))
                            .font(CTFont.regular(13))
                            .foregroundColor(Color.CT.textDim)
                        Spacer()
                        Toggle("", isOn: $notificationVibration)
                            .labelsHidden()
                            .tint(Color.CT.accent)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    CTSep()

                    // MARK: - Push Notifications
                    CTSettingsSectionHeader(title: NSLocalizedString("PUSH_NOTIFICATIONS", comment: "").uppercased())
                    #if targetEnvironment(macCatalyst)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(NSLocalizedString("push_not_available_mac", comment: ""))
                            .font(CTFont.regular(13))
                            .foregroundColor(Color.CT.textDim)
                        Text(NSLocalizedString("push_not_available_mac_hint", comment: ""))
                            .font(CTFont.regular(11))
                            .foregroundColor(Color.CT.textDim)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    #else
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(LocalizedStringKey("enable_push_notifications"))
                                .font(CTFont.regular(13))
                                .foregroundColor(Color.CT.textDim)
                            Text(LocalizedStringKey("push_notifications_footer"))
                                .font(CTFont.regular(11))
                                .foregroundColor(Color.CT.textDim)
                        }
                        Spacer()
                        Toggle("", isOn: $pushNotificationsEnabled)
                            .labelsHidden()
                            .tint(Color.CT.accent)
                            .disabled(authorizationStatus != .authorized)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)

                    CTSep(style: .thin)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizedStringKey("push_privacy_notice"))
                            .font(CTFont.regular(13))
                            .foregroundColor(Color.CT.textDim)
                        Text(LocalizedStringKey("push_privacy_notice_text"))
                            .font(CTFont.regular(11))
                            .foregroundColor(Color.CT.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    #endif
                    CTSep()
                }
            }
            .padding(.vertical, 20)
        }
        .onAppear {
            checkNotificationAuthorization()
        }
        }
        .background(Color.CT.bg.ignoresSafeArea())
    }

    // MARK: - Computed Properties
    private var statusIcon: String {
        switch authorizationStatus {
        case .authorized:
            return "[ok]"
        case .denied:
            return "[err]"
        case .notDetermined:
            return "[?]"
        case .provisional:
            return "[ok]"
        case .ephemeral:
            return "[ok]"
        @unknown default:
            return "[?]"
        }
    }

    private var statusColor: Color {
        switch authorizationStatus {
        case .authorized:
            return Color.CT.accent
        case .denied:
            return Color.CT.danger
        case .notDetermined:
            return .orange
        case .provisional:
            return Color.CT.accent
        case .ephemeral:
            return Color.CT.accent
        @unknown default:
            return Color.CT.textDim
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
        #if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #else
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/Notifications.prefPane"))
        #endif
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
        .preferredColorScheme(.dark)
}
