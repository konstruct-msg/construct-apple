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
        let deviceId = AppKeychain.presence("deviceId")
        let keyRecord = AppKeychain.presence("crypto_private_keys")
        log.notice("NSE run: group=\(group ?? "missing", privacy: .public) deviceId=\(deviceId, privacy: .public) keyRecord=\(keyRecord, privacy: .public)")
        contentHandler(ProbeBanner.marked(request.content, deviceId: deviceId, keyRecord: keyRecord))
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

/// The probe's answer on the banner itself, on a build installed from Xcode: there the result can
/// be read off the screen, where the extension's log is visible only to a Console stream already
/// running when the push lands. Two conditions, because `DEBUG` alone also covers the Beta
/// configuration TestFlight ships: an Xcode install carries `embedded.mobileprovision`, and
/// TestFlight and the App Store strip it. Neither carries the subtitle.
enum ProbeBanner {
    static func marked(_ content: UNNotificationContent, deviceId: String, keyRecord: String) -> UNNotificationContent {
        #if DEBUG
        guard isXcodeInstall, let marked = content.mutableCopy() as? UNMutableNotificationContent else { return content }
        marked.subtitle = "NSE · deviceId \(deviceId) · keyRecord \(keyRecord)"
        return marked
        #else
        return content
        #endif
    }

    private static var isXcodeInstall: Bool {
        Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil
    }
}
