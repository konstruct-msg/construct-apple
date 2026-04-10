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
        let status: String
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

    func markSentRequest(toUserId: String) {
        let key = "cr_sent_\(toUserId)"
        UserDefaults.standard.set(true, forKey: key)
    }

    // MARK: - Respond

    func accept(requestId: String) async throws {
        try await userServiceClient.respondToContactRequest(
            requestId: requestId,
            action: Shared_Proto_Services_V1_ContactRequestAction.accept
        )
        incomingRequests.removeAll { $0.id == requestId }
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
