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
        ScrollView {
            VStack(spacing: 20) {

                // MARK: - General Notifications
                VStack(alignment: .leading, spacing: 6) {
                    ConstructSection {
                        HStack(spacing: 14) {
                            Image(systemName: notificationsEnabled ? "bell.fill" : "bell.slash.fill")
                                .foregroundStyle(notificationsEnabled ? Color.CT.accent : Color.CT.textDim)
                                .frame(width: 22, alignment: .center)
                                .font(.system(size: 16))
                            Text(LocalizedStringKey("enable_notifications"))
                                .font(CTFont.bold(16))
                                .foregroundStyle(Color.CT.text)
                            Spacer()
                            Toggle("", isOn: $notificationsEnabled)
                                .labelsHidden()
                                .tint(Color.CT.accent)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                    Text(LocalizedStringKey("notifications_footer"))
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.textDim)
                        .padding(.horizontal, 20)
                }

                // MARK: - System Permission Status
                VStack(alignment: .leading, spacing: 6) {
                    ConstructSection(header: NSLocalizedString("system_notification_settings", comment: "").uppercased()) {
                        HStack(spacing: 14) {
                            Image(systemName: statusIcon)
                                .foregroundStyle(statusColor)
                                .frame(width: 22, alignment: .center)
                                .font(.system(size: 16))
                            Text(LocalizedStringKey("status"))
                                .font(CTFont.bold(16))
                                .foregroundStyle(Color.CT.text)
                            Spacer()
                            Text(statusText)
                                .font(CTFont.regular(14))
                                .foregroundStyle(Color.CT.textDim)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)

                        if authorizationStatus == .denied {
                            ConstructRowDivider(indent: 52)
                            ConstructButtonRow(
                                icon: "gear",
                                title: LocalizedStringKey("open_system_settings"),
                                iconColor: .orange
                            ) {
                                openSystemSettings()
                            }
                        } else if authorizationStatus == .notDetermined {
                            ConstructRowDivider(indent: 52)
                            ConstructButtonRow(
                                icon: "checkmark.circle.fill",
                                title: LocalizedStringKey("grant_permission"),
                                iconColor: Color.CT.accent
                            ) {
                                requestNotificationPermission()
                            }
                        }
                    }
                    if authorizationStatus == .denied {
                        Text(LocalizedStringKey("notification_permissions_required"))
                            .font(CTFont.regular(11))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 20)
                    } else {
                        Text(LocalizedStringKey("system_settings_footer"))
                            .font(CTFont.regular(11))
                            .foregroundStyle(Color.CT.textDim)
                            .padding(.horizontal, 20)
                    }
                }

                // MARK: - Message Notifications
                if notificationsEnabled {
                    ConstructSection(header: NSLocalizedString("MESSAGE_NOTIFICATIONS", comment: "")) {
                        HStack(spacing: 14) {
                            Image(systemName: "message.fill")
                                .foregroundStyle(showMessageNotifications ? Color.CT.accent : Color.CT.textDim)
                                .frame(width: 22, alignment: .center)
                                .font(.system(size: 16))
                            Text(LocalizedStringKey("show_message_notifications"))
                                .font(CTFont.bold(16))
                                .foregroundStyle(Color.CT.text)
                            Spacer()
                            Toggle("", isOn: $showMessageNotifications)
                                .labelsHidden()
                                .tint(Color.CT.accent)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)

                        ConstructRowDivider(indent: 52)

                        HStack(spacing: 14) {
                            Image(systemName: notificationSound ? "speaker.wave.2.fill" : "speaker.slash.fill")
                                .foregroundStyle(notificationSound ? Color.CT.accent : Color.CT.textDim)
                                .frame(width: 22, alignment: .center)
                                .font(.system(size: 16))
                            Text(LocalizedStringKey("notification_sound"))
                                .font(CTFont.bold(16))
                                .foregroundStyle(Color.CT.text)
                            Spacer()
                            Toggle("", isOn: $notificationSound)
                                .labelsHidden()
                                .tint(Color.CT.accent)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)

                        ConstructRowDivider(indent: 52)

                        HStack(spacing: 14) {
                            Image(systemName: "iphone.radiowaves.left.and.right")
                                .foregroundStyle(notificationVibration ? .purple : Color.CT.textDim)
                                .frame(width: 22, alignment: .center)
                                .font(.system(size: 16))
                            Text(LocalizedStringKey("vibration"))
                                .font(CTFont.bold(16))
                                .foregroundStyle(Color.CT.text)
                            Spacer()
                            Toggle("", isOn: $notificationVibration)
                                .labelsHidden()
                                .tint(Color.CT.accent)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }

                    // MARK: - Push Notifications
                    ConstructSection(header: NSLocalizedString("PUSH_NOTIFICATIONS", comment: "")) {
                        #if targetEnvironment(macCatalyst)
                        HStack(spacing: 12) {
                            Image(systemName: "desktopcomputer")
                                .foregroundStyle(Color.CT.textDim)
                                .frame(width: 22, alignment: .center)
                                .font(.system(size: 16))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(NSLocalizedString("push_not_available_mac", comment: ""))
                                    .font(CTFont.bold(16))
                                    .foregroundStyle(Color.CT.text)
                                Text(NSLocalizedString("push_not_available_mac_hint", comment: ""))
                                    .font(CTFont.regular(12))
                                    .foregroundStyle(Color.CT.textDim)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        #else
                        HStack(spacing: 14) {
                            Image(systemName: "bell.badge.fill")
                                .foregroundStyle(pushNotificationsEnabled ? .orange : Color.CT.textDim)
                                .frame(width: 22, alignment: .center)
                                .font(.system(size: 16))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(LocalizedStringKey("enable_push_notifications"))
                                    .font(CTFont.bold(16))
                                    .foregroundStyle(Color.CT.text)
                                Text(LocalizedStringKey("push_notifications_footer"))
                                    .font(CTFont.regular(12))
                                    .foregroundStyle(Color.CT.textDim)
                            }
                            Spacer()
                            Toggle("", isOn: $pushNotificationsEnabled)
                                .labelsHidden()
                                .tint(Color.CT.accent)
                                .disabled(authorizationStatus != .authorized)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)

                        ConstructRowDivider(indent: 52)

                        // Privacy Notice
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: "lock.shield.fill")
                                .foregroundStyle(Color.CT.accent)
                                .frame(width: 22, alignment: .center)
                                .font(.system(size: 16))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(LocalizedStringKey("push_privacy_notice"))
                                    .font(CTFont.bold(14))
                                    .foregroundStyle(Color.CT.text)
                                Text(LocalizedStringKey("push_privacy_notice_text"))
                                    .font(CTFont.regular(12))
                                    .foregroundStyle(Color.CT.textDim)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        #endif
                    }
                }
            }
            .padding(.vertical, 20)
        }
        .background(Color.CT.bg.ignoresSafeArea())
        .navigationTitle("notifications")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.CT.bgMsg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        #endif
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
}
