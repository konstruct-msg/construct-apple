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

    /// The remote username search under the Synaps search bar.
    enum RemoteSearchState {
        case idle
        case searching
        case found(Shared_Proto_Services_V1_UserProfile)
        case notFound
    }

    var remoteState: RemoteSearchState = .idle
    /// Optimistic / session UI for “request sent” — UserDefaults alone does not invalidate the view.
    private(set) var pendingSentUserIds: Set<String> = []
    private(set) var sendingRequestToUserId: String?

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
            self.error = error.userFacingMessage
        }
    }

    // MARK: - Send

    /// Returns the new request ID. Populates `from_identity` from the local current user
    /// so the recipient inbox shows a human-readable sender without a profile fetch.
    @discardableResult
    func sendRequest(toUserId: String) async throws -> String {
        let identity = currentSenderIdentity()
        return try await userServiceClient.sendContactRequest(
            toUserId: toUserId,
            username: identity.username,
            displayName: identity.displayName
        )
    }

    // MARK: - Remote search

    func resetSearch() {
        remoteState = .idle
    }

    /// Looks `username` up on the server; skipped when a local contact already matches.
    func search(username: String, localMatchesExist: Bool) async {
        guard !localMatchesExist else { return }
        remoteState = .searching

        do {
            guard let userId = try await userServiceClient.findUser(username: username) else {
                remoteState = .notFound
                return
            }
            let profile = try await userServiceClient.getUserProfile(userId: userId)
            remoteState = .found(profile)
        } catch {
            remoteState = .notFound
        }
    }

    func isRequestAlreadySent(toUserId: String) -> Bool {
        if pendingSentUserIds.contains(toUserId) { return true }
        return hasPendingSentRequest(toUserId: toUserId)
    }

    /// Sends a contact request to a discoverable user found via remote search.
    func sendContactRequest(to profile: Shared_Proto_Services_V1_UserProfile) async {
        guard !isRequestAlreadySent(toUserId: profile.userID) else { return }
        sendingRequestToUserId = profile.userID
        defer { sendingRequestToUserId = nil }
        do {
            let requestId = try await sendRequest(toUserId: profile.userID)
            markSentRequest(toUserId: profile.userID, requestId: requestId)
            // Drive visible “request sent” state (UserDefaults alone is not @Observable).
            pendingSentUserIds.insert(profile.userID)
            remoteState = .found(profile)
        } catch {
            // Surface the failure instead of swallowing it — a silent catch here hid the
            // real reason "Send request" did nothing (RPC rejected / no delivery). Log the
            // exact error and tell the user so it's retryable and diagnosable.
            // Transport blips surface as gRPC "Stream unexpectedly closed." — map to a
            // human-readable connection message (RPC already retried in UserServiceClient).
            Log.error("sendContactRequest failed for \(profile.userID.prefix(8))…: \(error)", category: "ContactRequest")
            // A connection failure gets the request's own sentence; anything else, the general one.
            // Classified by type, not by sniffing the error's words for "stream" or "timeout".
            let appError = AppError.from(error)
            if case .network = appError {
                ErrorRouter.shared.report(.said(UserText("contact_request_send_failed")))
            } else {
                ErrorRouter.shared.report(appError)
            }
        }
    }

    /// Local current-user identity used for the request-time snapshot (same source as QR/share).
    private func currentSenderIdentity() -> (username: String?, displayName: String?) {
        guard let userId = AuthSessionManager.shared.currentUserId else { return (nil, nil) }
        return (resolveUsername(for: userId), resolveDisplayName(for: userId))
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
    /// - Returns: The new contact's row.
    @discardableResult
    func accept(request: IncomingRequest) async throws -> ContactRecord {
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
            displayName: displayName
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
        guard !userId.isEmpty else { return nil }
        return (try? LocalRepositories.contacts.contact(userId))?.displayName
    }

    private func resolveUsername(for userId: String) -> String? {
        guard !userId.isEmpty else { return nil }
        return (try? LocalRepositories.contacts.contact(userId))?.username
    }

    private func normalizedValue(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Prefer request-time snapshot (server `from_*` fields), then local Core Data cache,
    /// then best-effort profile fetch. Snapshot is the authoritative early UX hint until
    /// the long-term contact/profile pipeline catches up after accept.
    private func resolveIncomingIdentity(
        fromUserId: String,
        fallbackDisplayName: String?,
        fallbackUsername: String?
    ) async -> (displayName: String?, username: String?) {
        let requestDisplayName = fallbackDisplayName.flatMap(normalizedValue)
        let requestUsername = fallbackUsername.flatMap(normalizedValue)
        if requestDisplayName != nil || requestUsername != nil {
            return (requestDisplayName, requestUsername)
        }

        let cachedDisplayName = resolveDisplayName(for: fromUserId)
        let cachedUsername = resolveUsername(for: fromUserId)
        if cachedDisplayName != nil || cachedUsername != nil {
            return (cachedDisplayName, cachedUsername)
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
    func checkAcceptedRequests() async -> [ContactRecord] {
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
