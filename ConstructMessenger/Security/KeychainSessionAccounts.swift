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
//  The `session_` namespace has three tenants and only two of them are session state:
//
//      session_<ServerUserId>           live ratchet blob     → delete
//      session_archives_<ServerUserId>  archived sessions     → delete
//      session_token                    the auth token        → KEEP
//
//  That last one is why the fix is not `hasPrefix("session_")`. `deleteAllE2EESessions()` is
//  called from `prepareForDeviceLink()`, which runs while the user is still signed in — a
//  prefix match would sign them out in the middle of linking a device.
//

import Foundation

enum KeychainSessionAccounts {
    static let prefix = "session_"
    private static let archiveInfix = "archives_"

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

    /// A `ServerUserId` (36-char dashed UUID) or a `CryptoDeviceId` (32 hex chars).
    private static func isIdentityShaped(_ id: String) -> Bool {
        if UUID(uuidString: id) != nil { return true }
        return id.count == 32 && id.allSatisfy(\.isHexDigit)
    }
}
