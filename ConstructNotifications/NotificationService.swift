//
//  NotificationService.swift
//  Konstruct Notifications
//
//  The notification service extension (construct-docs todo 124,
//  decisions/notification-extension-reads-only.md). On a message alert it fetches what is
//  waiting, asks the core what each delivery is (`NotificationPeek`) and drops the alert only
//  when every one is a protocol frame — a delivery receipt, a call signal. It reads the app's
//  keychain and writes nothing anywhere; every path in doubt shows the alert as it came.
//
//  Dropping needs Apple's filtering entitlement. Until `KonstructFiltersAlerts` is set in
//  Info.plist (with the entitlement), a frame-only push is shown and logged as "would hide".
//

import UserNotifications
import Security
import os

private let log = Logger(subsystem: "konstruct.notifications", category: "service")

final class NotificationService: UNNotificationServiceExtension {

    /// Our own limit, inside the system's ~30 s.
    private static let budget: Duration = .seconds(20)
    private static let fetchTimeout: Duration = .seconds(8)

    private let delivery = OneDelivery()

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        delivery.arm(original: request.content, handler: contentHandler)
        let delivery = self.delivery
        Task {
            let decision = await withTaskGroup(of: AlertDecision?.self) { group in
                group.addTask { await Self.decide() }
                group.addTask { try? await Task.sleep(for: Self.budget); return nil }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first ?? .show(reason: "over budget")
            }
            delivery.finish(decision)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        delivery.finish(.show(reason: "system time expired"))
    }

    private static func decide() async -> AlertDecision {
        guard ExtensionDirectPath.permits(AppKeychain.data(KeychainSessionAccounts.extensionDirectPath)) else {
            return .show(reason: "no direct path")
        }
        guard let snapshot = KeychainSnapshot.read() else {
            return .show(reason: "keychain incomplete")
        }
        let page: PendingPage
        do {
            page = try await PendingFetch.page(snapshot.credentials, timeout: fetchTimeout)
        } catch {
            log.notice("NSE fetch failed: \(String(describing: error), privacy: .public)")
            return AlertDecision.decide(fetch: .failed, verdicts: [])
        }
        let peek: NotificationPeek
        do {
            peek = try NotificationPeek(
                keyRecord: snapshot.keyRecord,
                myUserId: snapshot.credentials.deviceId,
                orchestratorState: snapshot.orchestratorState
            )
        } catch {
            return .show(reason: "peek unavailable")
        }
        let sessions = KeychainSessions()
        let verdicts = page.deliveries.map {
            peek.peek(messageId: $0.messageId, sealedInner: $0.sealedInner, sessions: sessions)
        }
        return AlertDecision.decide(
            fetch: .fetched(hasMore: page.hasMore, unsealed: page.unsealed),
            verdicts: verdicts
        )
    }
}

/// Hands the system exactly one content, whichever of the decision and the deadline comes first.
private final class OneDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var original: UNNotificationContent?
    private var handler: ((UNNotificationContent) -> Void)?

    static var filtersAlerts: Bool {
        Bundle.main.object(forInfoDictionaryKey: "KonstructFiltersAlerts") as? Bool ?? false
    }

    func arm(original: UNNotificationContent, handler: @escaping (UNNotificationContent) -> Void) {
        lock.withLock {
            self.original = original
            self.handler = handler
        }
    }

    func finish(_ decision: AlertDecision) {
        let taken: (UNNotificationContent, (UNNotificationContent) -> Void)? = lock.withLock {
            guard let original, let handler else { return nil }
            self.handler = nil
            return (original, handler)
        }
        guard let (original, handler) = taken else { return }

        switch decision {
        case .hide(let frames) where Self.filtersAlerts:
            log.notice("NSE: hide — \(frames, privacy: .public) protocol frame(s)")
            handler(UNNotificationContent())
        case .hide(let frames):
            log.notice("NSE: would hide — \(frames, privacy: .public) protocol frame(s); not entitled, shown")
            handler(ProbeBanner.marked(original, "\(frames) frame(s) · would hide"))
        case .show(let reason):
            log.notice("NSE: show — \(reason, privacy: .public)")
            handler(ProbeBanner.marked(original, reason))
        }
    }
}

/// The app's keychain, read from this process. The app writes with no access group, so its items
/// live in the group named by its application identifier; this extension declares that group and
/// names it on every query — a query keyed off `Bundle.main` here would search the extension's
/// own identifier and silently find nothing. Account names are `KeychainSessionAccounts`'s, the
/// one place they are spelled.
enum AppKeychain {
    /// `$(AppIdentifierPrefix)maximeliseyev.constructmessenger`, expanded into Info.plist at build.
    static let accessGroup = Bundle.main.object(forInfoDictionaryKey: "KonstructKeychainGroup") as? String

    static func data(_ account: String) -> Data? {
        guard let accessGroup else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func string(_ account: String) -> String? {
        data(account).map { String(decoding: $0, as: UTF8.self) }
    }
}

/// Everything the fetch and the peek need, or nothing.
private struct KeychainSnapshot {
    let credentials: PendingFetch.Credentials
    let keyRecord: Data
    let orchestratorState: Data?

    static func read() -> KeychainSnapshot? {
        typealias A = KeychainSessionAccounts
        guard let endpoint = AppKeychain.string(A.serverEndpoint).flatMap(ServerEndpoint.init),
              let token = AppKeychain.string(A.sessionToken),
              let userId = AppKeychain.string(A.userId),
              let deviceId = AppKeychain.string(A.deviceId),
              let keyRecord = AppKeychain.data(A.keyRecord)
        else { return nil }
        return KeychainSnapshot(
            credentials: .init(
                host: endpoint.host, port: endpoint.port, token: token, userId: userId,
                deviceId: deviceId, cursor: AppKeychain.string(A.streamCursor)
            ),
            keyRecord: keyRecord,
            orchestratorState: AppKeychain.data(A.orchestratorState)
        )
    }
}

/// Session states as the app stored them, handed to the core by device when a peek asks.
private final class KeychainSessions: PeekSessionSource, @unchecked Sendable {
    func session(deviceId: String) -> Data? {
        AppKeychain.data(KeychainSessionAccounts.account(for: deviceId))
    }
}

/// The decision on the banner itself, on a build installed from Xcode: there the result can be
/// read off the screen, where the extension's log is visible only to a Console stream already
/// running when the push lands. Two conditions, because `DEBUG` alone also covers the Beta
/// configuration TestFlight ships: an Xcode install carries `embedded.mobileprovision`, and
/// TestFlight and the App Store strip it. Neither carries the subtitle.
private enum ProbeBanner {
    static func marked(_ content: UNNotificationContent, _ text: String) -> UNNotificationContent {
        #if DEBUG
        guard isXcodeInstall, let marked = content.mutableCopy() as? UNMutableNotificationContent else { return content }
        marked.subtitle = "NSE · \(text)"
        return marked
        #else
        return content
        #endif
    }

    private static var isXcodeInstall: Bool {
        Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil
    }
}
