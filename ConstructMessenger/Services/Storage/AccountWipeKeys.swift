//
//  AccountWipeKeys.swift
//  Construct Messenger
//
//  Which `UserDefaults` keys a local account wipe removes, and which survive it on purpose.
//
//  This used to be an inline array in `AuthViewModel.deleteAccountLocally`, and it drifted the way
//  hand-maintained lists do: `construct.stream.cursor` was never in it, so a wipe left the resume
//  cursor behind. On 2026-08-20 that cursor had been stuck at 31 July for three weeks, and the
//  tester's "delete everything and start clean" did not touch it — every clean start immediately
//  re-pulled three weeks of backlog and the app died under it. `construct.session.vanishedPeers`
//  was missing too, added the previous day by the person writing this comment.
//
//  A longer list would drift again. What stops it is that **every** `construct.*` literal in the
//  app sources must appear in one of the lists below, enforced by `AccountWipeKeysTests`, which
//  reads the source and fails on an unclassified one. Adding a store now forces a decision instead
//  of allowing an omission, and the decision is written down next to its reason.
//
//  The lists are explicit rather than a `construct.` prefix sweep because the groups are not
//  separable by name: `construct.deviceId` must go and `construct.ice_relays` must not, and no
//  naming rule distinguishes them.
//

import Foundation

enum AccountWipeKeys {

    /// Removed by a local account wipe: anything scoped to the identity, its session, its crypto
    /// state, or its message history.
    static let wiped: [String] = [
        // Session / identity
        "construct.userId",
        "construct.deviceId",
        "construct.localStore.ownerUserId",
        "construct.pendingRegistrationBundle",
        "session_expires",
        "is_discoverable",
        "recovery_is_setup",
        "recovery_banner_dismissed",

        // Security surface
        "biometricEnabled",
        "pinLength",

        // Stream position. The omission that prompted this file: leaving it behind means the next
        // identity resumes from the previous one's watermark.
        "construct.stream.cursor",
        "construct.pendingCursor",
        "construct.lastMessageId",

        // Crypto / ratchet state
        "construct.orchestrator_state",
        "construct.orchestrator_state.afu_migrated.v1",
        "construct.cryptoKeys.afu_migrated.v2",
        "construct.healing_queue_state",
        "construct.kyber_session_state",
        "construct.kyber.otpk.nextKeyId",
        "construct.kyber.spk.id",
        "construct.kyber.spk.public",
        "construct.kyber.spk.secret",
        "construct.spk.lastRotationTimestamp",
        "construct.spk.uploadTimestamp",
        "construct.hybridIdentity.published.v1",
        "construct.hybridIdentity.spkFingerprint.v1",

        // Sealed sender — the cert belongs to the old identity.
        "construct.sealed_sender_cert",
        "construct.sealed_sender_cert_expiry",
        "construct.sealed_sender_cert_owner",
        "construct.session.vanishedPeers",

        // Key transparency counters describe this identity's verification history.
        "construct.kt_last_verified_at",
        "construct.kt_last_failed_at",
        "construct.kt_failure_count",
        "construct.kt_verified_count",
        "construct.kt_consecutive_success",

        // Per-contact / per-message UI and delivery state
        "construct.contactKeyChangeAcknowledged",
        "construct.openChatForKeyChange",
        "construct.inviteAcceptedContactCreated",
        "construct.adMigration.serverUUID.v1.done",
        "construct.media_send_cache_v1",
        "construct.manifest_signed_at",

        // Feature toggles that are user choices, not device capabilities
        "veil_enabled",
        "veil_mode",
        "trafficProtection_enabled",
        "backgroundFetch_enabled",
        "backgroundFetch_intervalMinutes"
    ]

    /// Key **prefixes** removed by a wipe — families with one entry per contact or message.
    static let wipedPrefixes: [String] = [
        "construct.contact_request_seen.",
        "construct.outgoingWirePayload.",
        "construct.kyber.otpk.sk.",
        "construct.pq_deferred."
    ]

    /// Survives a wipe, each for a stated reason. Being on this list is a claim that the value is
    /// about the *device or the server*, not about who is signed in.
    static let survives: [String] = [
        // Network topology caches. Re-fetched anyway; wiping them only costs a slow first connect,
        // and on a censored network that first connect is the one that matters most.
        "construct.ice_relays",
        "construct.ice_relay_infos",
        "construct.ice_relay_regions",
        "construct.ice_deprecated_relay_ids",
        "construct.geoip_ip_v1",
        "construct.geoip_region_v1",

        // Server-provided public material, identical for every identity on this server. Dropping
        // it would leave sealed-sender attestation unable to vouch anything until a refetch.
        "construct.bundle_signing_key",
        "construct.server.token_enc_pub",
        "construct.server.token_enc_pub.fetched_at",

        // Device-level app preferences.
        "customServerURL",
        "appTheme",
        "tz_offset_min"
    ]

    /// In the `construct.` namespace but **not a `UserDefaults` key at all**, so neither list above
    /// can honestly hold it: `survives` asserts that a stored value is about the device rather than
    /// the signed-in identity, and these store nothing.
    ///
    /// The bucket exists because the enforcing test scans for `"construct.*"` string literals, not
    /// for defaults keys — it cannot tell the difference, and that is deliberate, since a real key
    /// is easiest to miss when it looks like something else. So the classification has to have a
    /// place for the something-elses. Added 2026-08-21, when `construct.reaction.didChange` (a
    /// `Notification.Name`) reddened the suite and the only alternatives were to file a broadcast
    /// channel under "survives a wipe" or to teach the scanner a distinction it should not trust.
    static let notStorage: [String] = [
        // Suite / container names. These identify a store; wiping its contents is the prefix sweep
        // above or the store's own teardown.
        "construct.app",
        "construct.OutgoingWirePayloadStore",
        "construct.PendingReassemblyStore",
        "construct.ReceiptResendThrottle",
        "construct.reassembly_store_key",

        // Notification names.
        "construct.reaction.didChange"
    ]

    /// Apply the wipe to `defaults`.
    static func wipe(_ defaults: UserDefaults = .standard) {
        wiped.forEach { defaults.removeObject(forKey: $0) }
        let families = wipedPrefixes
        defaults.dictionaryRepresentation().keys
            .filter { key in families.contains { key.hasPrefix($0) } }
            .forEach { defaults.removeObject(forKey: $0) }
    }
}
