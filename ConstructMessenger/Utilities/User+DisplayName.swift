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
    /// 2. `displayName` if non-empty and not the generated name (profile-shared real name or
    ///    server username)
    /// 3. `username` if non-empty (server-assigned handle, shown without @)
    /// 4. Generated deterministic name from `id` (always non-nil fallback)
    ///
    /// A generated name held in `displayName` is skipped rather than shown: it stands in for "no
    /// name", and showing it hid a username the contact did have. Until 2026-10-02 a profile from
    /// Android carrying its generated name replaced the username taken from the invite.
    var resolvedDisplayName: String {
        ContactName.resolved(alias: localAlias, displayName: displayName, username: username, id: id)
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
        let names = ContactName.applyingServerUsername(
            serverUsername, username: username, displayName: displayName,
            isSharingWithMe: isSharingWithMe, id: userId ?? id
        )
        username = names.username
        displayName = names.displayName
    }
}

/// The name shown for a person — one rule for a `User` row and a `ContactRecord`, so the two cannot
/// show the same contact under different names while both exist (`User.resolvedDisplayName` says
/// why each step is where it is).
enum ContactName {
    static func resolved(alias: String?, displayName: String, username: String, id: String) -> String {
        if let alias = alias?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty {
            return alias
        }
        if !displayName.isEmpty, !DisplayNameGenerator.isGenerated(displayName, for: id) { return displayName }
        if !username.isEmpty { return username }
        return DisplayNameGenerator.generate(from: id)
    }

    /// The names a server-provided username leaves a person with — the rule
    /// `User.applyServerUsername` documents, as values, so a write through `ContactStore.setNames`
    /// follows it too.
    static func applyingServerUsername(
        _ serverUsername: String?, username: String, displayName: String,
        isSharingWithMe: Bool, id: String
    ) -> (username: String, displayName: String) {
        var username = username
        var displayName = displayName
        let trimmed = (serverUsername ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let isReal = !trimmed.isEmpty
            && trimmed.lowercased() != "anonymous"
            && UUID(uuidString: trimmed) == nil

        if isReal {
            username = trimmed
            if !isSharingWithMe {
                // Only overwrite displayName when we don't have a profile-shared name.
                displayName = trimmed
            }
        } else {
            // No real username: reset only placeholders — never discard a name that arrived
            // from an invite payload or a previous server update.
            let usernameIsPlaceholder = username.isEmpty
                || username.lowercased() == "anonymous"
                || UUID(uuidString: username) != nil
            if usernameIsPlaceholder { username = "" }

            if !isSharingWithMe {
                let displayIsPlaceholder = displayName.isEmpty || UUID(uuidString: displayName) != nil
                if displayIsPlaceholder { displayName = DisplayNameGenerator.generate(from: id) }
            }
        }
        return (username, displayName)
    }
}

// MARK: - Profile version

extension User {
    /// Our own name or avatar changed: the profile we send carries this as its version
    /// (`ProfileShare.editedAtMs`), so contacts apply it over the one they hold and ignore older ones.
    func markProfileEdited(now: Date = Date()) {
        profileEditedAtMs = Int64((now.timeIntervalSince1970 * 1000).rounded())
    }
}
