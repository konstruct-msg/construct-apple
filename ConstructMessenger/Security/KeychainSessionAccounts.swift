//
//  KeychainSessionAccounts.swift
//  Construct Messenger
//
//  Which Keychain accounts hold Double Ratchet session state — and which ones merely look
//  like they do.
//
//  INCIDENT (found 2026-08-08): `deleteAllSessions()` enumerated with
//  `kSecAttrService == Bundle.main.bundleIdentifier`, but `KeychainManager.save` has never
//  written `kSecAttrService` at all. The query matched nothing, so the wipe deleted nothing:
//  every `session_<contactId>` ratchet blob survived account deletion and device link, and
//  the two log lines that would have said so ("Deleted N session(s)") only print when N > 0.
//  A wipe that silently wipes nothing is the same defect shape as a test that asserts
//  nothing — it occupies the place where someone would otherwise have looked.
//
//  The `session_` namespace has three tenants and only two of them are session state. The first
//  two rows are the shapes still written today; the next two are shapes that exist on devices
//  that have been through an earlier version and must still be recognised, because a wipe that
//  does not name them leaves ratchet state behind:
//
//      session_<CryptoDeviceId>            live ratchet blob      → delete    (written today)
//      session_archives_<CryptoDeviceId>   archived sessions      → delete    (written today)
//      session_<ServerUserId>              pre-flip ratchet       → delete    (legacy on disk)
//      session_<ServerUserId>:<DeviceId>   pre-flip per-device    → delete    (legacy on disk)
//      session_token                       the auth token         → KEEP
//
//  SECOND INCIDENT (found 2026-08-26): the per-device row above was missing, and the file said
//  in as many words that it could not exist — "No such id should exist (see UserIdentity.swift
//  — session addressing is ServerUserId)". It has existed since multi-device shipped:
//  `MultiDeviceSendCoordinator.sessionKey(userId:deviceId:)` produced `<uuid>:<hex>`, which was
//  neither shape then listed, so every per-device ratchet blob survived `deleteAllE2EESessions()` —
//  called from `prepareForDeviceLink()` and `resetOrchestratorStateForDeviceLink()`, i.e. at
//  exactly the moment whose whole purpose is that the next identity cannot inherit the previous
//  one's ratchet state. The same defect as 2026-08-08, one shape further along, and the comment
//  ruling it out is why nobody looked.
//
//  That last one is why the fix is not `hasPrefix("session_")`. `deleteAllE2EESessions()` is
//  called from `prepareForDeviceLink()`, which runs while the user is still signed in — a
//  prefix match would sign them out in the middle of linking a device.
//
//  `sessionKey(userId:deviceId:)` no longer exists: since `SessionAddressing` a contactId is a
//  bare `CryptoDeviceId` and nothing composes one. The colon branch below is kept for the blobs
//  that composition already wrote, and is the only reason it is still parsed.
//

import Foundation

enum KeychainSessionAccounts {
    static let prefix = "session_"
    private static let archiveInfix = "archives_"

    // MARK: - Where the core's durable slots land

    /// Accounts that are not session state but are named here anyway, because this file is the
    /// one place the Keychain namespace is spelled.
    static let orchestratorState = "construct.orchestrator_state"
    static let kyberSessionState = "construct.kyber_session_state"
    static let pqDeferredPrefix = "construct.pq_deferred."
    static let kyberSignedPrekeyPrefix = "construct.kyber.spk.sk."

    /// The account a core `SecureStoreSlot` is stored under on this platform.
    ///
    /// The core used to send a formatted key (`"session_<id>"`, `"archive_<id>"`, …) and this
    /// side parsed it back apart, then rebuilt an identical string two layers down in
    /// `KeychainManager`. Six copies of one naming rule across two repositories, and the one in
    /// `CallManager` silently did nothing for every slot that was not a session. The core now
    /// says only *what* the bytes are; where they live is decided here and nowhere else.
    ///
    /// Android maps the same slots onto Keystore without inheriting any of these names.
    static func account(for slot: CfeSecureStoreSlot) -> String {
        switch slot {
        case .session(let contactId):
            return account(for: contactId)
        case .sessionArchive(let contactId):
            // The account the archive *list* lives under. Archives are a JSON list of
            // `SessionArchive`, not a single blob, so the write goes through
            // `SessionArchiveManager` — which builds its key from this same function.
            return prefix + archiveInfix + contactId
        case .pqDeferred(let contactId):
            return pqDeferredPrefix + contactId
        case .kyberSessionState:
            return kyberSessionState
        case .kyberSignedPrekey(let keyId):
            return "\(kyberSignedPrekeyPrefix)\(keyId)"
        case .orchestratorState:
            return orchestratorState
        }
    }

    /// True for accounts holding Double Ratchet state for one contact, live or archived.
    ///
    /// Identified by the shape of the suffix rather than by a denylist of the neighbours:
    /// a denylist protects `session_token` only until someone adds `session_something_else`,
    /// and they will not read this file when they do. Requiring an identity-shaped suffix
    /// fails in the safe direction — an unrecognised account is left alone.
    ///
    /// NOT COVERED: a blob written under a contact id in neither shape below is not matched
    /// and survives the wipe. No such id should exist (see `UserIdentity.swift` — session
    /// addressing is `ServerUserId`), and `CryptoDeviceId` is accepted anyway because the
    /// historical ID-space mix-up could have produced it. If a third shape ever appears, it
    /// will show up here as a leftover, not as a deleted auth token.
    static func isSessionState(_ account: String) -> Bool {
        guard account.hasPrefix(prefix) else { return false }
        var suffix = account.dropFirst(prefix.count)
        if suffix.hasPrefix(archiveInfix) {
            suffix = suffix.dropFirst(archiveInfix.count)
        }
        return isIdentityShaped(String(suffix))
    }

    /// A `ServerUserId` (36-char dashed UUID), a `CryptoDeviceId` (32 hex chars), or the
    /// per-device pair `<ServerUserId>:<CryptoDeviceId>` the multi-device session layer writes.
    ///
    /// The pair is split on the colon and both halves checked, rather than matched by a looser
    /// pattern: a shape that accepts anything containing a colon would start deleting whatever
    /// tenant of this namespace is added next, and the point of this predicate is to fail in the
    /// safe direction.
    private static func isIdentityShaped(_ id: String) -> Bool {
        if let colon = id.firstIndex(of: ":") {
            let user = String(id[id.startIndex..<colon])
            let device = String(id[id.index(after: colon)...])
            return isSingleIdentityShaped(user) && isSingleIdentityShaped(device)
        }
        return isSingleIdentityShaped(id)
    }

    private static func isSingleIdentityShaped(_ id: String) -> Bool {
        if UUID(uuidString: id) != nil { return true }
        return id.count == 32 && id.allSatisfy(\.isHexDigit)
    }

    /// The account name for a session, and the only place it is spelled.
    ///
    /// Both the wipe and the peer-device index read this namespace, and a second definition of
    /// "what a session account looks like" is how the two incidents above happened.
    static func account(for contactId: String) -> String { prefix + contactId }

    /// True for a **live** session account — not an archive.
    ///
    /// `isSessionState` deliberately accepts both, because the wipe must reach both. A reader that
    /// wants sessions to restore wants only the live ones: an archive has no current ratchet, and
    /// restoring from one would count a failure for every peer that ever had a session reset.
    static func isLiveSession(_ account: String) -> Bool {
        isSessionState(account) && !account.hasPrefix(prefix + archiveInfix)
    }

    /// The contact id a session account names, or `nil` when the account is not session state.
    static func contactId(ofAccount account: String) -> String? {
        guard isSessionState(account) else { return nil }
        var suffix = account.dropFirst(prefix.count)
        if suffix.hasPrefix(archiveInfix) { suffix = suffix.dropFirst(archiveInfix.count) }
        return String(suffix)
    }

    /// The `(userId, deviceId)` a per-device session account names, or `nil` for the plain form.
    ///
    /// This is what makes the session store its own device index: the set of a peer's devices we
    /// hold sessions with is derivable from the accounts already on disk, so nothing has to keep
    /// a second list in agreement with it.
    static func perDeviceContact(ofAccount account: String) -> (userId: String, deviceId: String)? {
        guard let contactId = contactId(ofAccount: account),
              let colon = contactId.firstIndex(of: ":") else { return nil }
        return (String(contactId[contactId.startIndex..<colon]),
                String(contactId[contactId.index(after: colon)...]))
    }
}
