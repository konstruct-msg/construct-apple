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
    /// 1. `localAlias` if non-empty (local-only override the user assigned; never leaves
    ///    the device) — wins over everything so the user always sees the name they chose
    /// 2. `displayName` if non-empty (profile-shared real name or server username)
    /// 3. `username` if non-empty (server-assigned handle, shown without @)
    /// 4. Generated deterministic name from `id` (always non-nil fallback)
    var resolvedDisplayName: String {
        if let alias = localAlias?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty {
            return alias
        }
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
            if !isSharingWithMe {
                // Only overwrite displayName when we don't have a profile-shared name.
                // isSharingWithMe == true → contact sent us their real name; keep it.
                displayName = trimmed
            }
        } else {
            // Server has no real username for this contact.
            // Only reset username/displayName if current value is a placeholder
            // (empty, UUID, or "anonymous") — never discard a name that arrived
            // from an invite payload or a previous server update.
            let currentUsernameIsPlaceholder = username.isEmpty
                || username.lowercased() == "anonymous"
                || UUID(uuidString: username) != nil

            if currentUsernameIsPlaceholder {
                username = ""
            }

            if !isSharingWithMe {
                let currentDisplayIsPlaceholder = displayName.isEmpty
                    || UUID(uuidString: displayName) != nil
                if currentDisplayIsPlaceholder {
                    displayName = DisplayNameGenerator.generate(from: resolvedId)
                }
            }
            // isSharingWithMe == true → keep existing displayName (profile-shared name)
        }
    }
}
