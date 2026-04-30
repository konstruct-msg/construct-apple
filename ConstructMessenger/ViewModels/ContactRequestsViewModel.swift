import Foundation
import CoreData

@MainActor
@Observable
final class ContactRequestsViewModel {

    // MARK: - State

    struct IncomingRequest: Identifiable {
        let id: String
        let fromUserId: String
        let createdAt: Date

        /// Display name resolved from CoreData local cache (may be nil if sender is unknown).
        var displayName: String?
        var username: String?
    }

    struct SentRequest: Identifiable {
        let id: String
        let status: Shared_Proto_Services_V1_ContactRequestStatus
        let createdAt: Date
    }

    var incomingRequests: [IncomingRequest] = []
    var sentRequests: [SentRequest] = []
    var isLoading = false
    var error: String?

    // MARK: - Dependencies

    private let userServiceClient = UserServiceClient.shared
    private let viewContext: NSManagedObjectContext

    init(viewContext: NSManagedObjectContext) {
        self.viewContext = viewContext
    }

    // MARK: - Load

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let result = try await userServiceClient.getContactRequests()

            incomingRequests = result.incoming.map { proto in
                var req = IncomingRequest(
                    id: proto.requestID,
                    fromUserId: proto.fromUserID,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(proto.createdAt))
                )
                // Resolve display info from local CoreData cache.
                req.displayName = resolveDisplayName(for: proto.fromUserID)
                req.username = resolveUsername(for: proto.fromUserID)
                return req
            }

            sentRequests = result.sent.map { proto in
                SentRequest(
                    id: proto.requestID,
                    status: proto.status,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(proto.createdAt))
                )
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Send

    /// Returns the new request ID, or nil if duplicate pending.
    @discardableResult
    func sendRequest(toUserId: String) async throws -> String {
        try await userServiceClient.sendContactRequest(toUserId: toUserId)
    }

    /// Returns true if sender already has a pending sent request to `toUserId`.
    func hasPendingSentRequest(toUserId: String) -> Bool {
        // Sent requests do not expose toUserId — use a local cache keyed in UserDefaults.
        let key = "cr_sent_\(toUserId)"
        return UserDefaults.standard.bool(forKey: key)
    }

    func markSentRequest(toUserId: String, requestId: String) {
        UserDefaults.standard.set(true, forKey: "cr_sent_\(toUserId)")
        // Store request_id → to_user_id so we can look up who accepted on User A's side.
        UserDefaults.standard.set(toUserId, forKey: "cr_reqid_\(requestId)")
    }

    // MARK: - Respond

    /// Accepts an incoming contact request and creates a contact entry in CoreData.
    ///
    /// - Parameters:
    ///   - request: The full incoming request (contains fromUserId, displayName, username).
    ///   - context: CoreData context to write the new User into.
    /// - Returns: The created or updated `User` entity for the new contact.
    @discardableResult
    func accept(request: IncomingRequest, context: NSManagedObjectContext) async throws -> User {
        try await userServiceClient.respondToContactRequest(
            requestId: request.id,
            action: Shared_Proto_Services_V1_ContactRequestAction.accept
        )
        incomingRequests.removeAll { $0.id == request.id }
        return try ContactLinkService.shared.createOrUpdateContact(
            userId: request.fromUserId,
            username: request.username,
            displayName: request.displayName,
            context: context
        )
    }

    func declineAndBlock(requestId: String) async throws {
        try await userServiceClient.respondToContactRequest(
            requestId: requestId,
            action: Shared_Proto_Services_V1_ContactRequestAction.declineBlock
        )
        incomingRequests.removeAll { $0.id == requestId }
    }

    func reportSpamAndBlock(requestId: String) async throws {
        try await userServiceClient.respondToContactRequest(
            requestId: requestId,
            action: Shared_Proto_Services_V1_ContactRequestAction.spamBlock
        )
        incomingRequests.removeAll { $0.id == requestId }
    }

    // MARK: - Private helpers

    private func resolveDisplayName(for userId: String) -> String? {
        guard let uuid = UUID(uuidString: userId) else { return nil }
        let request = NSFetchRequest<User>(entityName: "User")
        request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
        request.fetchLimit = 1
        return try? viewContext.fetch(request).first?.displayName
    }

    private func resolveUsername(for userId: String) -> String? {
        guard let uuid = UUID(uuidString: userId) else { return nil }
        let request = NSFetchRequest<User>(entityName: "User")
        request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
        request.fetchLimit = 1
        return try? viewContext.fetch(request).first?.username
    }
}

// MARK: - Accepted request polling (User A side)

extension ContactRequestsViewModel {

    /// Checks whether any previously sent contact requests have been accepted.
    /// For each newly-accepted request, creates the contact in CoreData and returns
    /// the list of newly-linked users so the caller can navigate to the new chat.
    ///
    /// Username/displayName resolution: the server never stores plaintext usernames.
    /// User A searched for User B before sending the request, so their data is already
    /// in the local CoreData cache. ContactLinkService will find and preserve it.
    /// If CoreData has no entry yet (e.g. after reinstall), a generated name is used
    /// and updated later via session profile sharing.
    ///
    /// Call this on `SynapsView.task` and whenever the app comes to the foreground.
    ///
    /// - Parameter context: CoreData context to write new contacts into.
    /// - Returns: Array of newly-created `User` entities (one per accepted request).
    @discardableResult
    func checkAcceptedRequests(context: NSManagedObjectContext) async -> [User] {
        do {
            let result = try await userServiceClient.getContactRequests()
            var newContacts: [User] = []

            for sent in result.sent where sent.status == .accepted {
                let requestId = sent.requestID
                let udKey = "cr_reqid_\(requestId)"
                guard let toUserId = UserDefaults.standard.string(forKey: udKey),
                      !toUserId.isEmpty else { continue }

                // Remove the key first to prevent duplicate runs on concurrent calls.
                UserDefaults.standard.removeObject(forKey: udKey)
                UserDefaults.standard.removeObject(forKey: "cr_sent_\(toUserId)")

                do {
                    // No getUserProfile call — server never returns plaintext username.
                    // ContactLinkService will reuse the existing CoreData entry for this
                    // user (populated when User A searched for them) or create a new one
                    // with a generated name that gets resolved via session profile sharing.
                    let user = try ContactLinkService.shared.createOrUpdateContact(
                        userId: toUserId,
                        username: nil,
                        displayName: nil,
                        context: context
                    )
                    newContacts.append(user)
                    Log.info("✅ Contact request accepted by \(toUserId) — contact created", category: "ContactRequests")
                } catch {
                    Log.error("⚠️ Failed to create contact for accepted request \(requestId): \(error)", category: "ContactRequests")
                    // Restore the key so it retries next time.
                    UserDefaults.standard.set(toUserId, forKey: udKey)
                    UserDefaults.standard.set(true, forKey: "cr_sent_\(toUserId)")
                }
            }

            // Refresh our local sentRequests list with the latest server state.
            sentRequests = result.sent.map { proto in
                SentRequest(
                    id: proto.requestID,
                    status: proto.status,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(proto.createdAt))
                )
            }

            return newContacts
        } catch {
            Log.error("⚠️ checkAcceptedRequests failed: \(error)", category: "ContactRequests")
            return []
        }
    }
}
