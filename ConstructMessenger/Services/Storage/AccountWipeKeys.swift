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
        // Keychain: the at-rest store key. `LocalDataWipe` deletes it first; listed so the scan
        // knows it is the account's.
        "construct.localStore.key.v1",
        // Ids of first messages that failed to open, kept by builds before 2026-11-08
        // (`FailedInitMessageStore`, removed with todo/252) — the account's.
        "com.construct.failed_init_message_ids",
        "construct.pendingRegistrationBundle",
        // Notes not yet moved into the store (`NotesStore`).
        NotesStore.storageKey,

        // Named without the `construct.` prefix, so the scan did not require them until todo/281;
        // on the stand of 2026-11-07 a wipe left `ct.device_link.fp.user.<account id>` behind.
        // Owed to the server and sent by whoever is signed in next: blocks by contact id
        // (`BlockSync`), contact-request acks (`ContactRequestAcks`), our profile to contacts.
        "block_sync_pending",
        "cr_accepted_acks",
        "profileRebroadcastOwed",
        // Account ids that finished orientation, and the flag before it was per account.
        "orientation_completed_user_ids",
        "orientation_completed",
        // Removed by sign-out's own teardown too; listed so account deletion and the other wipe
        // paths, which go straight to `LocalDataWipe`, remove them as well.
        "local_display_name",
        "recovery_is_setup",
        "recovery_banner_dismissed",
        "cr_pending_nav_user_ids",
        // A restore the account chose and the next launch would carry out (`LocalBackupService`).
        "ct.pending_restore",
        // Senders this account suppressed, persisted until 2026-10-15 and cleared at launch since.
        "com.construct.floodguard.suppressed",
        // Bundled sticker packs seeded, and retired ones offered, to this account. The packs
        // themselves go with the files; a mark left behind would keep the next account from ever
        // getting them (`BundledStickerPacks`).
        "stickers.bundled.seeded",
        "stickers.bundled.retired",
        // Keychain items, deleted by the calls that end an account rather than by `wipe(_:)`:
        // the key record and the legacy private key (`CryptoManager.deleteAllCryptoKeys`), the
        // contact-request mappings (`KeychainManager.deleteAllContactRequestMappings`), and the
        // blind tokens this account was issued (`TokenWalletService.forget`).
        "crypto_private_keys",
        "private_key",
        "cr_request_mappings",
        "stealth_token_wallet_v2",
        // This account's intake key, and the note of which epoch we last published tags for.
        // Wiped together: a new account minting a fresh key while the old publish marker says
        // "already done today" would publish nothing until tomorrow, and every contact would pay
        // for a day with nothing on this device saying why.
        "construct.intake.own",
        "construct.intake.lastPublishedEpoch.v1",
        // This account's address (its recovery public key). The next identity has another, and a
        // stale one here would go into every invite it mints — contacts would write to an
        // address that is not theirs, and the server would drop it silently.
        "construct.accountAddress",
        // Who already holds our key. Wiped because the new account's key is a different secret —
        // a stale list would suppress the lazy hand-off to every contact it names. Both versions:
        // v2 is keyed by device (2026-09-22) and v1 by account, and a wipe that left the older one
        // behind would leave a list nothing reads and nothing clears.
        "construct.intake.sentTo.v3",
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

        // Keychain: the recovery phrase waiting to be uploaded or copied (`RecoveryPhraseVault`).
        // `LocalDataWipe` deletes both, on sign-out as on deletion; listed so the scan knows they
        // are the account's. The sign-out warning fires while a copy is still owed.
        "construct.recovery.phrase.pending",
        "construct.recovery.phrase.held",
        // When the silent key was made, whether its copy was confirmed, and the reminder's
        // snooze (`RecoveryBackupMarks`). The account's; the next one starts with none.
        "construct.recovery.silentAt",
        "construct.recovery.silentAccount",
        "construct.recovery.copied",
        "construct.recovery.reminderSnoozedUntil",

        // The reactions this person uses most (`ReactionQuickSetStore`). A habit of this
        // identity's; the next one starts from the popular set.
        "construct.reactions.quickSet.v1",

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
        "construct.fanoutRetryQueue.v2",
        // The invites this account minted (`IssuedInviteStore`). Left behind, the next account's
        // Settings would list codes it never issued and offer to revoke them — under a token that
        // is not theirs. `invite_journal_v1` is where they were kept until 2026-10-11, never in
        // this list; it went with no wipe at all.
        "construct.issuedInvites.v2",
        "invite_journal_v1",
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
        // Which Kyber SPK (device:keyId) the server confirmed. Belongs to this identity's keys:
        // kept across a wipe it would tell the next identity its SPK was already published.
        "construct.kyber.v2.published",

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
        // Contacts' device sets as last listed. Nothing writes it since the new-device alarm went
        // (2026-09-30); kept here so installs that wrote it lose it with the account.
        "construct.peerDeviceSets.listed.v1",
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
        // The mailbox-gap notice not yet closed (`MailboxGapNotice`): about this account's
        // messages. Lives in the key-value store — `UserDefaults` on an iOS install that has not
        // moved to construct.db, where this wipe is what removes it.
        "construct.mailboxGap.v1",
        "construct.mailboxGap.v2",
        "construct.mailboxGap.v3",
        // How far each chat is read, per partner (`ReadBoundaries`, TODO 152): this account's
        // reading, which another account must not inherit.
        "construct.readBoundaries.v1",
        "construct.readBoundaries.v2",
        // Unread counts per chat at the last trip to the background (`UnreadSeen`, construct-ios
        // #248): chat ids of this account, and the baseline its banners are withdrawn against.
        "construct.notifications.unreadSeen",
        // The public IP and region the removed GeoIP lookup cached. `GRPCChannelManager` already
        // deletes them at launch; listed so a wipe says the same about where the person was.
        "construct.geoip_ip_v1",
        "construct.geoip_region_v1",

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
        // Which contact devices were judged (`PeerDeviceJudgement`). The account's: a mark left
        // behind would read a device as trusted for the next person on this phone.
        "construct.peerDeviceJudged.",
        "construct.outgoingWirePayload.",
        // Intake keys a peer handed us. Wiped: they are the peers' secrets, held only so our
        // envelopes to them owe no token, and an account that is gone has no envelopes to send.
        // Keeping them would leave one person's contact graph readable in the next person's
        // Keychain.
        "construct.intake.peer.",
        "construct.tokenSpendUnit.v1.",
        "construct.kyber.otpk.sk.",
        "construct.pq_deferred.",
        // Not `construct.`-named, so the scan does not require them; listed because they are the
        // account's: thumbnail JPEGs of builds before 2026-08-11 (`ThumbnailStore` moved them to
        // Caches, and a failed move leaves them here).
        "message_thumbnail_",
        // The per-peer PQXDH downgrade flag of builds before PQXDH v2 (Keychain). Nothing writes
        // it any more; `KyberPrekeyService.deleteLegacyItems` sweeps what an older build left.
        "construct.pqxdh.downgraded.",
        // The copy of a session's suite that builds before 2026-11-07 kept (Keychain). Nothing
        // writes it any more; `KeychainManager.deleteRetiredSessionSuiteIds` sweeps it at launch.
        "construct.session.suite.",
        // Where `SecureStoreSlot.KyberSignedPrekey` would land. No reachable emitter today
        // (`commit_spk_rotation` is called only from its own tests), but a secret key that
        // appears must leave with the account, and classifying it now costs nothing.
        "construct.kyber.spk.sk.",
        // The link pins (`DeviceLinkPendingPin`): the offering device's fingerprint by token and by
        // account id, the "bundle only" mark, and a sibling's identity key by device id.
        "ct.device_link.",
        // Per peer: when an at-risk session last tried to upgrade.
        "session.atRiskUpgrade.lastAttempt.",
        // Keychain: every ratchet session blob (`KeychainManager.deleteAllKeys`). In
        // `UserDefaults` the same prefix sweeps `session_last_activity_<peer>`, when a session last
        // carried a message (`SessionActivityTracker`).
        "session_"
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
        // When the relay manifest was last fetched and accepted (`VeilCertFetcher`): a throttle on
        // the fetch of public, server-wide data. Wiped, the next launch only fetches again early.
        "construct.manifest_last_accepted",

        // Server-provided public material, identical for every identity on this server. Dropping
        // it would leave sealed-sender attestation unable to vouch anything until a refetch.
        "construct.bundle_signing_key",
        "construct.server.token_enc_pub",
        "construct.server.token_enc_pub.fetched_at",
        // Delegations of the server's hybrid keys — root-signed public data, the same for everyone.
        "construct.server.trust_delegations",

        // Which store this install stands on: construct-store once iOS has moved to it
        // (`LocalStoreImport`). A wipe replaces the store with an empty one and stays on it.
        "construct.localStore.active.v1",

        // Device-level app preferences.
        "customServerURL",
        "appTheme",
        "tz_offset_min",
        "textSize",
        "chatTextFace",
        "chat.ownedInsetStack",
        "desktopShowTimestamps",
        "continuousVoicePlayback",
        "voice.playbackRate",
        "gallery.videoPlaybackRate",
        "composer.sendOriginalPhotos",
        "composer.videoQuality",
        "media.autoDownload",
        "media.evictAfterDays",
        "media.maxDiskCacheBytes",
        "call.audio.inputUID",
        "call.audio.outputUID",
        "notificationsEnabled",
        "pushNotificationsEnabled",
        "showMessageNotifications",
        "notificationPreviewType",
        "notificationSound",
        "notificationVibration",
        "sendDeliveryReceipts",
        "backgroundFetchEnabled",
        "stt_auto_transcribe",
        "stt_engine",
        "stt_language",
        "stt_preferred_model",
        "stt_translate",

        // The app lock: the person's PIN, duress PIN and biometrics, kept in the Keychain and
        // removed only by turning the lock off (`SecurityViewModel.disablePin`). A lock on the
        // phone, not on the account, as it was before this list named it.
        "app_pin_hash",
        "app_pin_hash_version",
        "app_pin_salt",
        "app_pin_length",
        "app_duress_pin_hash",
        "app_duress_pin_hash_version",
        "app_duress_pin_salt",
        "security.lockDelay",
        "security.useBiometrics",

        // The network path this device found: relays, fronts, their scores and the keys VEIL
        // uses, the same for whoever is signed in. Wiped, the next connect on a censored network
        // starts from nothing.
        "veilActiveRelay",
        "veil_access_key",
        "veil_auto_detected_dpi",
        "veil_bridge_cert",
        "veil_front_enabled",
        "veil_front_native_tls",
        "veil_last_successful_path",
        "veil_learned_fronts",
        "veil_relay_quality_scores_v1",
        "veil_scores_key",
        "veil.voucher.unavailable_until",
        "com.construct.ice.webTunnelBlockedPenalty",
        "grpcCustomHost",
        "grpcCustomPort",

        // Developer and test switches, and Studio's, set by hand on this device.
        "developerModeEnabled",
        "ff.callsVideo",
        "ff.engineQuicExperimental",
        "ff.engineQuicObfuscated",
        "stealth_mode_enabled",
        "StudioDebug",
        "StudioSendsScreen",
        "StudioSourceBundleID",
        "StudioTalkbackMode",

        // Done once per install. The store marks describe a store a wipe replaces with a new one;
        // the key repairs describe keys a new identity is created without the defect they repair.
        "synaps_contact_migration_v1",
        "storage.controlArtifactCleanup.v1.done",
        "hybrid_spk_sig_heal_v1",
        "pqcKyberSPKMigrationV1Done",
        "crash_diagnostics_recorded_v1",
        // Built by interpolation (`VeilProxyStore`), so no scan finds it; seen on the stand of
        // 2026-11-08 among what a wipe left, and about the network path, like the VEIL keys above.
        "veil_mode_migration_v1",
        // Removed at launch by `StealthPolicy`; nothing writes it.
        "stealth_per_message"
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
        // `construct.fanoutRetryQueue.v2`, which is in `wiped` — the two live a few lines apart in
        // one file and mean opposite things here, which is why the scan reads literals rather than
        // trusting a name to say what it is.
        "construct.FanoutRetryQueue",
        "construct.PendingReassemblyStore",
        "construct.ReceiptResendThrottle",
        "construct.reassembly_store_key",
        // The file name of the encrypted local store (`LocalStoreSession`), not a defaults key. A
        // wipe removes the file with the container sweep, after destroying its key
        // (`LocalDataWipe.run`).
        "construct.db",
        // A Keychain item `KeychainPlacement` writes and deletes in the same breath to learn
        // whether the build may use the data protection keychain. Never left behind.
        "construct.keychain.placement_probe",

        // A Keychain item: the key this device labels VEIL front names under in its logs
        // (`LogRedaction`). About the device, not the account; kept so labels stay comparable.
        "construct.logLabel.key.v1",

        // A key inside construct.db (`LocalStoreImport.completedKey`), not in `UserDefaults`; it
        // goes with the store.
        "construct.localStore.importedFromCoreData.v1",
        // Same, `LegacyBodyUpgrade.doneKey`.
        "construct.localStore.legacyMediaBodiesConverted.v1",

        // Notification names.
        "construct.reaction.didChange",

        // Found by the wider scan of todo/281, which reads constants named `…Key` or `…Prefix`:
        // prefixes of wire ids and transport names, a URL, a gRPC metadata key, a WebRTC field
        // trial, a JSON key, a notification's `userInfo` key, resource and localization names.
        "KNST1:",
        "direct:",
        "veil:",
        "konstruct://add",
        "construct-device-refusal",
        "WebRTC-EnableDtlsPqc",
        "presentation",
        "callId",
        "sticker-pack-",
        "history_sync_body_local_network",
        "history_sync_body_local_network_mac",
        // Constants nothing reads or writes (`APIConstants`).
        "last_username",
        "user_id"
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
