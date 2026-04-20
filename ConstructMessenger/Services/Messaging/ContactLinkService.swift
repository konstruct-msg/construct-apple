//
//  ContactLinkService.swift
//  Construct Messenger
//
//  Creates or updates a contact User entity in CoreData from server-provided
//  identity data (contact request acceptance, invite redemption, etc.).
//
//  Display name priority (same as User+DisplayName.swift):
//    1. server displayName if non-empty and not a placeholder
//    2. server username if non-empty and not a UUID / "anonymous"
//    3. generated deterministic fallback via DisplayNameGenerator
//

import Foundation
import CoreData

@MainActor
final class ContactLinkService {

    static let shared = ContactLinkService()
    private init() {}

    // MARK: - Create or update contact

    /// Creates or updates a `User` entity in CoreData for the given remote contact.
    ///
    /// - Parameters:
    ///   - userId: Remote user ID (non-empty UUID string).
    ///   - username: Server username handle (may be nil/empty → falls back to displayName or generated).
    ///   - displayName: Human-readable name provided by the server (may be nil/empty).
    ///   - context: Managed object context to save into.
    /// - Returns: The created or updated `User` entity.
    @discardableResult
    func createOrUpdateContact(
        userId: String,
        username: String?,
        displayName: String?,
        context: NSManagedObjectContext
    ) throws -> User {
        guard !userId.isEmpty else { throw ContactLinkError.emptyUserId }

        let fetchRequest = User.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", userId)
        fetchRequest.fetchLimit = 1

        let user: User
        if let existing = try context.fetch(fetchRequest).first {
            user = existing
        } else {
            user = User(context: context)
            user.id = userId
            user.addedAt = Date()
            user.isBlocked = false
            user.isSharingWithMe = false
            user.amISharingWith = false
        }

        user.isContact = true

        // applyServerUsername handles username priority and sets displayName to
        // the username when no profile-shared name is present.
        user.applyServerUsername(username, userId: userId)

        // If the server provided an explicit displayName that is not a placeholder,
        // prefer it over the username-derived name — unless isSharingWithMe is true
        // (in that case the contact already shared their real name with us).
        if let dn = displayName, !dn.isEmpty, !user.isSharingWithMe {
            let isPlaceholder = UUID(uuidString: dn) != nil || dn.lowercased() == "anonymous"
            if !isPlaceholder {
                user.displayName = dn
            }
        }

        try context.save()
        return user
    }

    // MARK: - Errors

    enum ContactLinkError: LocalizedError {
        case emptyUserId

        var errorDescription: String? {
            switch self {
            case .emptyUserId: return "Contact user ID must not be empty."
            }
        }
    }
}
