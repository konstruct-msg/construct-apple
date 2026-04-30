// UserIdentity.swift
// Construct Messenger
//
// Typed wrappers for the two distinct user-identity spaces.
//
// WHY THIS EXISTS — historical bug postmortem:
//   The Double Ratchet AD is constructed as:
//     ENCRYPT: AD_VERSION || local_user_id || contact_id || …
//     DECRYPT: AD_VERSION || contact_id   || local_user_id || …
//   Both parties must agree on the identity space.  The server UUID
//   (ServerUserId) is the canonical routing identity known to all parties;
//   the CryptoDeviceId is a device-local hash used only for multi-device
//   linking and QR codes.  Mixing the two formats causes permanent AEAD
//   failure with no other error signal — the compiler cannot catch this if
//   both are plain String.  These types make the boundary explicit.

/// The server-assigned account UUID (36 chars, dashes included, e.g. "14f28d31-…").
/// This is the ONLY identity that should cross the Swift ↔ Rust FFI boundary
/// for session addressing (`local_user_id`, `contact_id`, `conversation_id`).
struct ServerUserId: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    var description: String { rawValue }
}

/// The device-local crypto identity derived from the identity public key
/// (32 hex chars, e.g. "6f5e37ac…").  Used for multi-device linking and
/// QR codes only.  NEVER pass this to the Rust session layer.
struct CryptoDeviceId: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    var description: String { rawValue }
}
