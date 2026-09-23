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
        // This account's intake key, and the note of which epoch we last published tags for.
        // Wiped together: a new account minting a fresh key while the old publish marker says
        // "already done today" would publish nothing until tomorrow, and every contact would pay
        // for a day with nothing on this device saying why.
        "construct.intake.own",
        "construct.intake.lastPublishedEpoch.v1",
        // Who already holds our key. Wiped because the new account's key is a different secret —
        // a stale list would suppress the lazy hand-off to every contact it names. Both versions:
        // v2 is keyed by device (2026-09-22) and v1 by account, and a wipe that left the older one
        // behind would leave a list nothing reads and nothing clears.
        "construct.intake.sentTo.v2",
        "construct.intake.sentTo.v1",
        // Peers whose credential the server refused, by epoch. Same shape as `sentTo`: a list of
        // who this account talks to, meaningless — and misleading — under the next account.
        "construct.intake.rejected.v1",
        "session_expires",
        "is_discoverable",
        "recovery_is_setup",
        "recovery_banner_dismissed",

        // Security surface
        "biometricEnabled",
        "pinLength",

        // Contacts this identity pruned. Named `construct.*` in 2026-09-04 precisely so this list
        // has to claim it: under its old `com.konstruct.*` name it escaped the scan below, and a
        // wipe left one identity's pruned contacts shielding the next identity's messages.
        "construct.deletedContacts.v2",

        // Stream position. The omission that prompted this file: leaving it behind means the next
        // identity resumes from the previous one's watermark.
        "construct.stream.cursor",
        "construct.pendingCursor",
        "construct.lastMessageId",

        // Crypto / ratchet state
        "construct.orchestrator_state",
        "construct.orchestrator_state.afu_migrated.v1",
        "construct.cryptoKeys.afu_migrated.v2",
        // The second healing queue, gone 2026-09-23 (step 4). Still wiped: a build predating the
        // change may have written one, and a stale queue restored onto a fresh identity is the
        // ghost-identity audit of 2026-07-26.
        "construct.healing_queue_state",
        // "the dead `HealingMessage` rows have been emptied on this install". Not device-about,
        // so it leaves with the identity: a wipe empties the store anyway, and a flag claiming
        // work was done on data that no longer exists is the kind of leftover this list is for.
        "construct.healingMessage.purged.v1",
        // Copies this account's messages still owe to a recipient's devices (§C). Leaves with the
        // account for the same reason the wire-payload entries do: they name messages and peers of
        // the person signing out, and a drain after a re-registration would try to send them as
        // whoever signed in next.
        "construct.fanoutRetryQueue.v1",
        // The device set this account's metadata blob was last sealed for. Leaves with the
        // account: a stale marker after a re-registration would convince the next account that its
        // metadata was already published, and its row would stay unnamed on every sibling.
        "construct.deviceMetadata.publishedFor.v1",
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
        // One-shot cleanups, wiped with the account for the same reason as the migration above:
        // a wipe removes the data they were about, so carrying "already done" across it asserts
        // something about rows that no longer exist. Being wrong here costs one no-op pass; being
        // wrong the other way means the cleanup never runs again.
        "construct.selfAddressedResidue.cleared.v1",
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
        // Intake keys a peer handed us. Wiped: they are the peers' secrets, held only so our
        // envelopes to them owe no token, and an account that is gone has no envelopes to send.
        // Keeping them would leave one person's contact graph readable in the next person's
        // Keychain.
        "construct.intake.peer.",
        "construct.tokenSpendUnit.v1.",
        "construct.kyber.otpk.sk.",
        "construct.pq_deferred.",
        // Where `SecureStoreSlot.KyberSignedPrekey` would land. No reachable emitter today
        // (`commit_spk_rotation` is called only from its own tests), but a secret key that
        // appears must leave with the account, and classifying it now costs nothing.
        "construct.kyber.spk.sk."
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
        // A serial dispatch queue's label, not a defaults key. Its store is
        // `construct.fanoutRetryQueue.v1`, which is in `wiped` — the two live a few lines apart in
        // one file and mean opposite things here, which is why the scan reads literals rather than
        // trusting a name to say what it is.
        "construct.FanoutRetryQueue",
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
