import CoreData
import Foundation

/// Background-safe contact request acceptance handler.
///
/// Responsibilities:
/// - Creates CoreData contacts when a sent request is accepted (Keychain mapping lookup).
/// - Can run without any SwiftUI view being loaded (called from AppDelegate push handler).
/// - Stores created user IDs in UserDefaults so SynapsView can navigate on next open.
///
/// Idempotent: re-running after mapping is consumed is a safe no-op.
@MainActor
final class ContactRequestService {
    static let shared = ContactRequestService()
    private init() {}

    private let userServiceClient = UserServiceClient.shared
    private let keychain = KeychainManager.shared

    // UserDefaults key for user IDs created during background processing.
    // Persists across process kills; consumed by SynapsView on next foreground.
    private static let pendingNavKey = "cr_pending_nav_user_ids"

    // MARK: - Core check

    /// Fetches sent contact requests from the server and creates CoreData contacts for
    /// any that have been accepted. Safe to call from AppDelegate (background push) or
    /// from SynapsView.task (foreground poll) — whichever runs first owns the Keychain
    /// mapping; subsequent calls are a no-op for already-processed requests.
    ///
    /// - Returns: Newly created `User` entities (empty if no new acceptances).
    @discardableResult
    func checkAndCreateContacts() async -> [User] {
        let context = PersistenceController.shared.container.viewContext
        do {
            let result = try await userServiceClient.getContactRequests()
            var newContacts: [User] = []

            for sent in result.sent where sent.status == .accepted {
                let requestId = sent.requestID
                guard let toUserId = keychain.loadContactRequestMapping(requestId: requestId),
                      !toUserId.isEmpty else { continue }

                // Delete mapping first to prevent double-processing on concurrent calls.
                keychain.deleteContactRequestMapping(requestId: requestId)
                UserDefaults.standard.removeObject(forKey: "cr_sent_\(toUserId)")

                do {
                    let user = try ContactLinkService.shared.createOrUpdateContact(
                        userId: toUserId,
                        username: nil,
                        displayName: nil,
                        context: context
                    )
                    newContacts.append(user)
                    Log.info(
                        "✅ Contact created from accepted request: \(toUserId)",
                        category: "ContactRequests"
                    )
                } catch {
                    Log.error(
                        "⚠️ Failed to create contact for request \(requestId): \(error)",
                        category: "ContactRequests"
                    )
                    // Restore mapping so the next check can retry.
                    keychain.saveContactRequestMapping(requestId: requestId, toUserId: toUserId)
                    UserDefaults.standard.set(true, forKey: "cr_sent_\(toUserId)")
                }
            }

            if !newContacts.isEmpty {
                appendPendingNavigationUserIds(newContacts.map { $0.id })
                NotificationCenter.default.post(
                    name: .contactRequestAccepted,
                    object: nil
                )
            }

            return newContacts
        } catch {
            Log.error(
                "⚠️ ContactRequestService.checkAndCreateContacts failed: \(error)",
                category: "ContactRequests"
            )
            return []
        }
    }

    // MARK: - Pending navigation

    /// Returns user IDs of contacts created during background push processing.
    /// Drains the list — call once per SynapsView appearance.
    func consumePendingNavigationUserIds() -> [String] {
        let ids = UserDefaults.standard.stringArray(forKey: Self.pendingNavKey) ?? []
        UserDefaults.standard.removeObject(forKey: Self.pendingNavKey)
        return ids
    }

    private func appendPendingNavigationUserIds(_ ids: [String]) {
        var existing = UserDefaults.standard.stringArray(forKey: Self.pendingNavKey) ?? []
        existing.append(contentsOf: ids)
        UserDefaults.standard.set(existing, forKey: Self.pendingNavKey)
    }
}
