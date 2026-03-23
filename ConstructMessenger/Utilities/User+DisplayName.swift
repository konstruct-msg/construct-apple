//
//  User+DisplayName.swift
//  Construct Messenger
//
//  Single source of truth for contact display name resolution.
//

import Foundation

extension User {

    // MARK: - Read

    /// The best available display name for this contact.
    ///
    /// Priority:
    /// 1. `displayName` if non-empty (profile-shared real name or server username)
    /// 2. `username` if non-empty (server-assigned handle, shown without @)
    /// 3. Generated deterministic name from `id` (always non-nil fallback)
    var resolvedDisplayName: String {
        if !displayName.isEmpty { return displayName }
        if !username.isEmpty { return username }
        return DisplayNameGenerator.generate(from: id)
    }

    // MARK: - Write

    /// Updates `username` and `displayName` from a server-provided value.
    ///
    /// Rules:
    /// - If the server provides a real (non-empty, non-UUID, non-"anonymous") username:
    ///   → update both `username` and `displayName` to that value.
    /// - If the server provides no real username:
    ///   → update `username` to `""`.
    ///   → update `displayName` **only** when `isSharingWithMe == false`.
    ///     If the contact already shared their profile with us, their profile-shared
    ///     name is preserved — it must not be overwritten by a generated fallback.
    ///
    /// Call this method everywhere a server-sourced username is applied to a User
    /// entity (ChatManagementService, PublicKeyBundleHandler, ChatViewModel, …).
    ///
    /// - Parameters:
    ///   - serverUsername: Raw username string returned by the server (may be nil/empty/UUID).
    ///   - userId: The user's ID used to generate a fallback name; defaults to `self.id`.
    func applyServerUsername(_ serverUsername: String?, userId: String? = nil) {
        let resolvedId = userId ?? id
        let trimmed = (serverUsername ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let isReal = !trimmed.isEmpty
            && trimmed.lowercased() != "anonymous"
            && UUID(uuidString: trimmed) == nil

        if isReal {
            username = trimmed
            displayName = trimmed
        } else {
            username = ""
            if !isSharingWithMe {
                displayName = DisplayNameGenerator.generate(from: resolvedId)
            }
            // isSharingWithMe == true → keep existing displayName (profile-shared name)
        }
    }
}
