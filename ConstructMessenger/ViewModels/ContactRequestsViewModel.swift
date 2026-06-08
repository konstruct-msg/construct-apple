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

        Log.info("Loading contact requests", category: "ContactRequests")
        do {
            let result = try await userServiceClient.getContactRequests()

            var resolvedIncomingRequests: [IncomingRequest] = []
            resolvedIncomingRequests.reserveCapacity(result.incoming.count)

            for proto in result.incoming {
                var req = IncomingRequest(
                    id: proto.requestID,
                    fromUserId: proto.fromUserID,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(proto.createdAt))
                )
                let identity = await resolveIncomingIdentity(
                    fromUserId: proto.fromUserID,
                    fallbackDisplayName: proto.fromDisplayName,
                    fallbackUsername: proto.fromUsername
                )
                req.displayName = identity.displayName
                req.username = identity.username
                resolvedIncomingRequests.append(req)
            }
            incomingRequests = resolvedIncomingRequests

            sentRequests = result.sent.map { proto in
                SentRequest(
                    id: proto.requestID,
                    status: proto.status,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(proto.createdAt))
                )
            }
            Log.info(
                "Loaded contact requests: incoming=\(incomingRequests.count) sent=\(sentRequests.count)",
                category: "ContactRequests"
            )
        } catch {
            Log.error("Failed to load contact requests: \(error)", category: "ContactRequests")
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
        // cr_sent_* is a UI-only hint (no-duplicate guard in the UI); UserDefaults is fine.
        UserDefaults.standard.set(true, forKey: "cr_sent_\(toUserId)")
        // requestId→toUserId mapping goes to Keychain so it survives reinstall.
        KeychainManager.shared.saveContactRequestMapping(requestId: requestId, toUserId: toUserId)
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

        var displayName = request.displayName
        var username = request.username
        if displayName == nil && username == nil {
            let identity = await resolveIncomingIdentity(
                fromUserId: request.fromUserId,
                fallbackDisplayName: nil,
                fallbackUsername: nil
            )
            displayName = identity.displayName
            username = identity.username
        }

        let user = try ContactLinkService.shared.createOrUpdateContact(
            userId: request.fromUserId,
            username: username,
            displayName: displayName,
            context: context
        )

        // Rebuild the message-stream subscription set and prewarm the session for
        // the freshly-accepted contact. Without this the stream stays subscribed
        // to the pre-acceptance contact set, so the server delivers none of this
        // contact's messages (ChatsViewModel observes this notification and calls
        // forceReconnect). The sender side gets the same treatment via
        // ContactRequestService.checkAndCreateContacts.
        NotificationCenter.default.post(name: .contactRequestAccepted, object: nil)

        return user
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

    private func normalizedValue(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func resolveIncomingIdentity(
        fromUserId: String,
        fallbackDisplayName: String?,
        fallbackUsername: String?
    ) async -> (displayName: String?, username: String?) {
        let cachedDisplayName = resolveDisplayName(for: fromUserId)
        let cachedUsername = resolveUsername(for: fromUserId)
        if cachedDisplayName != nil || cachedUsername != nil {
            return (cachedDisplayName, cachedUsername)
        }

        let requestDisplayName = fallbackDisplayName.flatMap(normalizedValue)
        let requestUsername = fallbackUsername.flatMap(normalizedValue)
        if requestDisplayName != nil || requestUsername != nil {
            return (requestDisplayName, requestUsername)
        }

        do {
            let profile = try await userServiceClient.getUserProfile(userId: fromUserId)
            let profileDisplayName = profile.hasDisplayName ? normalizedValue(profile.displayName) : nil
            let profileUsername = profile.hasUsername ? normalizedValue(profile.username) : nil
            Log.info(
                "Resolved incoming request identity from profile for \(fromUserId.prefix(8))…",
                category: "ContactRequests"
            )
            return (profileDisplayName, profileUsername)
        } catch {
            Log.error(
                "Failed to resolve incoming request identity for \(fromUserId.prefix(8))…: \(error)",
                category: "ContactRequests"
            )
            return (nil, nil)
        }
    }
}

// MARK: - Accepted request polling (User A side)

extension ContactRequestsViewModel {

    /// Checks whether any previously sent contact requests have been accepted.
    /// Delegates contact creation to `ContactRequestService` (background-safe, Keychain-backed).
    /// Also refreshes the local `sentRequests` list for UI display.
    ///
    /// - Returns: Newly-created `User` entities. Empty if all acceptances were already
    ///   processed by a background push handler.
    @discardableResult
    func checkAcceptedRequests(context: NSManagedObjectContext) async -> [User] {
        // Contact creation: handled by service (idempotent, Keychain-backed).
        let newContacts = await ContactRequestService.shared.checkAndCreateContacts()

        // Refresh our local sentRequests list for UI (separate call; the service already
        // made one, but we need the result here to update observable state).
        if let result = try? await userServiceClient.getContactRequests() {
            sentRequests = result.sent.map { proto in
                SentRequest(
                    id: proto.requestID,
                    status: proto.status,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(proto.createdAt))
                )
            }
        }

        return newContacts
    }
}
