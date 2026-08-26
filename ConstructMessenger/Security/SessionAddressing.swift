//
//  SessionAddressing.swift
//  Construct Messenger
//
//  The one place a user id becomes a crypto identity.
//

import Foundation
import CoreData

/// Who a Double Ratchet session is with, in the only terms the ratchet understands.
///
/// ## Why this exists
///
/// Two identifier spaces meet here, and until 2026-08-26 they met by accident. The app is
/// user-centric: a conversation, a transcript, a contact row are all keyed by `ServerUserId`.
/// The protocol is device-centric: a ratchet is between two *devices*, and the associated data it
/// binds must name the same pair on both sides.
///
/// While every account had one device the two spaces could be confused for free, and they were:
/// `local_user_id` and `contact_id` were both server UUIDs. The moment a second device appeared,
/// the send path started addressing it as `<userId>:<deviceId>` while the receiver's own
/// `local_user_id` stayed a bare UUID — and the AD stopped mirroring, permanently, on every
/// per-device message. See `decisions/identity-is-a-set-of-keys.md`.
///
/// The fix is not a better join between the two spaces. It is that **the crypto layer never sees
/// the account space at all**: everything below this seam is a `CryptoDeviceId`.
///
/// ## Why a device id is a safe identity
///
/// `deviceId == SHA256(identity_public)[0..16]`, derived by `deriveDeviceId` in the core. It is
/// not an allocation the server hands out and could hand out differently — it is a function of the
/// key the peer publishes, so two clients that hold the same key compute the same id and there is
/// nothing to keep in agreement. That is also why nothing here caches one: a cached derivation is
/// a second carrier of the value it was derived from.
enum SessionAddressing {

    /// This device's crypto identity.
    ///
    /// Read from the Keychain rather than derived, because it is needed to *construct* the core
    /// that would derive it. `CryptoManager.verifyLocalIdentity` closes that loop once the core
    /// exists: the stored value is a cache of `deriveDeviceId(our identity public)`, and a cache
    /// that disagrees with its source is repaired there, loudly.
    static func localIdentity() -> String {
        KeychainManager.shared.loadDeviceID() ?? ""
    }

    /// The crypto identity of the peer behind `userId`, or `nil` when we have no way to name them.
    ///
    /// Derived from the identity key we pinned for that contact, so it needs no network, no cache
    /// and no fresh bundle — and it answers during a locked-device background decrypt, which the
    /// key server cannot.
    ///
    /// `nil` means "we have never verified this contact's key", which is the same state in which
    /// no session could exist either. Callers treat it as "no session", never as an error.
    static func cryptoIdentity(ofUser userId: String) -> String? {
        guard !userId.isEmpty else { return nil }
        guard let identityKey = pinnedIdentityKey(ofUser: userId), !identityKey.isEmpty else {
            return nil
        }
        return deriveDeviceId(identityPublicKey: [UInt8](identityKey))
    }

    /// Translate an id from the account space into the crypto space.
    ///
    /// This is the seam. **Above it** — view models, routers, Core Data — an id names a person:
    /// a `ServerUserId`. **Below it** — the Rust core, the Keychain session accounts, the AD of
    /// every ratchet — an id names a device: a `CryptoDeviceId`. Everything that crosses passes
    /// through here, and nothing else in the app is allowed to know both spaces.
    ///
    /// An id that is already a device id passes through unchanged. This branch is an
    /// **optimisation, not a correctness rule**: removing it is behaviour-preserving, because a
    /// device id has no `User` row and the resolution below then returns it unchanged anyway. It
    /// is here so the per-device paths — sender-sync, fan-out, candidate walking, all of which
    /// already hold a device id — do not take a Core Data fetch per call on the receive path.
    /// Mutating it away reddens nothing, and a test that pretended otherwise would be a test that
    /// cannot fail.
    ///
    /// Returns the input unchanged when the peer's identity key has never been pinned. That is
    /// the state in which no session exists either, so the call that follows fails as
    /// "no session" rather than being told a different, wrong thing — and it keeps a contact
    /// whose key we have not verified from being addressed as if we had.
    static func contactId(forPeer id: String) -> String {
        if SessionAddressing.isCryptoIdentity(id) { return id }
        guard let deviceId = SessionAddressing.cryptoIdentity(ofUser: id) else {
            Log.debug("No pinned identity key for \(id.prefix(8))… — cannot name a device", category: "Crypto")
            return id
        }
        return deviceId
    }

    /// True when `id` is already a crypto identity rather than an account id.
    ///
    /// Used only at the seam, to keep a caller that already holds a device id from being resolved
    /// a second time. Below the seam every id is a device id and this question does not arise.
    static func isCryptoIdentity(_ id: String) -> Bool {
        id.count == 32 && id.allSatisfy(\.isHexDigit)
    }

    // MARK: - Internals

    #if DEBUG
    /// Test seam: lets a unit test answer without a Core Data stack.
    nonisolated(unsafe) static var pinnedIdentityKeyOverrideForTesting: ((String) -> Data?)?
    #endif

    private static func pinnedIdentityKey(ofUser userId: String) -> Data? {
        #if DEBUG
        if let override = pinnedIdentityKeyOverrideForTesting { return override(userId) }
        #endif
        let ctx = PersistenceController.shared.container.viewContext
        let req = User.fetchRequest()
        req.predicate = NSPredicate(format: "id == %@", userId)
        req.fetchLimit = 1
        return (try? ctx.fetch(req).first)?.knownIdentityKey
    }
}
