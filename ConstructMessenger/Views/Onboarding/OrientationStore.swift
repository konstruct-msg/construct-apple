//
//  OrientationStore.swift
//  Construct Messenger
//
//  First-run product orientation (post identity init). Separate from registration.
//  Completion is **per ServerUserId** so a new identity on the same device always
//  sees the guide again (the old global bool skipped it forever after first Skip).
//

import Foundation

enum OrientationStore {
    /// Legacy global flag (pre per-user). Migrated into `completedUserIdsKey` once.
    static let legacyCompletedKey = "orientation_completed"
    /// `@AppStorage` / UserDefaults: comma-separated ServerUserIds that finished orientation.
    static let completedUserIdsKey = "orientation_completed_user_ids"

    /// Back-compat alias used by older call sites / docs.
    static let completedKey = completedUserIdsKey

    // MARK: - Query

    /// Whether this identity has finished (or skipped) orientation on this device.
    /// - Parameters:
    ///   - userId: Server user id; if nil/empty → not completed (show orientation).
    ///   - rawList: Current `@AppStorage` string (keeps SwiftUI reactive).
    static func isCompleted(for userId: String?, rawList: String) -> Bool {
        guard let userId, !userId.isEmpty else { return false }
        migrateLegacyIfNeeded(currentUserId: userId)
        let effective = UserDefaults.standard.string(forKey: completedUserIdsKey) ?? rawList
        return parse(effective).contains(userId)
    }

    // MARK: - Mutate

    /// Mark orientation finished for this identity. Updates `rawList` for `@AppStorage` binding.
    static func markCompleted(userId: String, rawList: inout String) {
        guard !userId.isEmpty else { return }
        var ids = parse(rawList)
        // Prefer freshest UserDefaults in case another writer migrated first.
        if let stored = UserDefaults.standard.string(forKey: completedUserIdsKey) {
            ids.formUnion(parse(stored))
        }
        ids.insert(userId)
        let serialized = serialize(ids)
        rawList = serialized
        UserDefaults.standard.set(serialized, forKey: completedUserIdsKey)
        UserDefaults.standard.removeObject(forKey: legacyCompletedKey)
    }

    /// Call on full local sign-out / wipe. Does **not** need to clear per-user history
    /// for other identities, but wipe-all is the simple privacy-friendly choice.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: legacyCompletedKey)
        UserDefaults.standard.removeObject(forKey: completedUserIdsKey)
    }

    // MARK: - Migration

    /// If the old global `orientation_completed == true` is set, credit the **current**
    /// user only (so upgrades don't re-show the guide for the active account).
    private static func migrateLegacyIfNeeded(currentUserId: String) {
        guard UserDefaults.standard.object(forKey: legacyCompletedKey) != nil else { return }
        let legacyTrue = UserDefaults.standard.bool(forKey: legacyCompletedKey)
        UserDefaults.standard.removeObject(forKey: legacyCompletedKey)
        guard legacyTrue else { return }

        var ids = parse(UserDefaults.standard.string(forKey: completedUserIdsKey) ?? "")
        ids.insert(currentUserId)
        UserDefaults.standard.set(serialize(ids), forKey: completedUserIdsKey)
        Log.info(
            "OrientationStore: migrated legacy global flag → user \(currentUserId.prefix(8))…",
            category: "Orientation"
        )
    }

    // MARK: - Encoding

    private static func parse(_ raw: String) -> Set<String> {
        Set(
            raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    private static func serialize(_ ids: Set<String>) -> String {
        ids.sorted().joined(separator: ",")
    }
}
