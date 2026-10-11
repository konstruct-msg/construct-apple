//
//  NotificationService.swift
//  Konstruct Notifications
//
//  The notification service extension (construct-docs todo 124,
//  decisions/notification-extension-reads-only.md). It reads the app's keychain and never
//  writes anything; the alert it is handed is shown unchanged on every path that is in doubt.
//
//  Step 3a: the target exists and proves, on a device, that it runs on a message push and reads
//  the app's keychain items without moving them into a new access group. The peek
//  (`NotificationPeek`) and the fetch come next; until then every alert is shown as it came.
//

import UserNotifications
import Security
import os

private let log = Logger(subsystem: "konstruct.notifications", category: "service")

final class NotificationService: UNNotificationServiceExtension {

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        let group = AppKeychain.accessGroup
        log.notice("NSE run: group=\(group ?? "missing", privacy: .public) deviceId=\(AppKeychain.presence("deviceId"), privacy: .public) keyRecord=\(AppKeychain.presence("crypto_private_keys"), privacy: .public)")
        contentHandler(request.content)
    }

    override func serviceExtensionTimeWillExpire() {
        // Nothing is held back yet; the system shows the original alert.
        log.notice("NSE time expired")
    }
}

/// The app's keychain, read from this process. The app writes with no access group, so its items
/// live in the group named by its application identifier; this extension declares that group and
/// names it on every query — a query keyed off `Bundle.main` here would search the extension's
/// own identifier and silently find nothing.
enum AppKeychain {
    /// `$(AppIdentifierPrefix)maximeliseyev.constructmessenger`, expanded into Info.plist at build.
    static let accessGroup = Bundle.main.object(forInfoDictionaryKey: "KonstructKeychainGroup") as? String

    /// "found", "missing" or the OSStatus — never the value.
    static func presence(_ account: String) -> String {
        guard let accessGroup else { return "no-group" }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: false,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess: return "found"
        case errSecItemNotFound: return "missing"
        default: return "status \(status)"
        }
    }
}
