//
//  CryptoManager.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//  Updated for UniFFI clean API on 26.12.2025
//
//  This class is now a Swift wrapper around the UniFFI-generated Rust `construct-core` library.
//  Rust handles ALL crypto operations internally - Swift just passes wire format.
//

import Foundation
import CoreData
import os.log

/// Singleton wrapper around the Rust `construct-core` FFI.
///
/// **Threading:** callable from any thread. Every stored property below is read and written under
/// `coreLock` — the mutable ones through accessors that take it — so `@unchecked Sendable` names
/// that lock. The Rust objects synchronise themselves. Until 2026-10-25 this comment required one
/// thread "in practice `@MainActor`", which the class did not enforce and SPK rotation, OTPK
/// replenishment, history and media decryption already broke; about fifty reads and writes ran
/// without the lock.
class CryptoManager: @unchecked Sendable {
    static let shared = CryptoManager()

    // Two-phase init: _bootstrapCore holds ClassicCryptoCore before userId is known;
    // orchestratorCore is created in setLocalUserId() once userId is available.
    // Works for both iOS and macOS Desktop (Strategy B: direct core path).
    // Internal access for InviteGenerator (needs to export keys)
    internal var orchestratorCore: OrchestratorCore? {
        get { withCoreLock { orchestratorCoreStorage } }
        set { withCoreLock { orchestratorCoreStorage = newValue } }
    }
    private var orchestratorCoreStorage: OrchestratorCore?

    /// True once OrchestratorCore has been successfully created from Keychain keys.
    var isInitialized: Bool {
        return orchestratorCore != nil
    }
    private var _bootstrapCore: ClassicCryptoCore? {
        get { withCoreLock { bootstrapCoreStorage } }
        set { withCoreLock { bootstrapCoreStorage = newValue } }
    }
    private var bootstrapCoreStorage: ClassicCryptoCore?
    var _cachedUserId: String? {
        get { withCoreLock { cachedUserIdStorage } }
        set { withCoreLock { cachedUserIdStorage = newValue } }
    }
    private var cachedUserIdStorage: String?

    /// Runs `body` with `coreLock` held. Recursive, so a locked section may call anything here.
    func withCoreLock<T>(_ body: () throws -> T) rethrows -> T {
        coreLock.lock()
        defer { coreLock.unlock() }
        return try body()
    }

    /// Returns the local identity for Double Ratchet AEAD associated data: **this device's id**.
    ///
    /// The AD is mirrored — the INITIATOR's `local_user_id` must equal the RESPONDER's
    /// `contact_id` for the same party, and vice versa — so both sides have to name the same
    /// thing. Until 2026-08-26 that thing was the server UUID, which works only while an account
    /// has one device: the moment a second appeared, the send path addressed it as
    /// `<userId>:<deviceId>` while this stayed a bare UUID, and the mirror broke permanently on
    /// every per-device message.
    ///
    /// A device id names a device, which is what a ratchet is actually between. See
    /// `SessionAddressing` for why it is safe to address by, and
    /// `decisions/identity-is-a-set-of-keys.md` for why the account space does not belong here
    /// at all.
    var cryptoLocalUserId: String {
        SessionAddressing.localIdentity()
    }

    private let coreProvider = CryptoCoreProvider()
    
    // Serializes all access to orchestratorCore and _bootstrapCore so that
    // callers on different threads (e.g. BackgroundFetchManager, MessageRouter)
    // don't race on Rust FFI state. Recursive to allow safe nested calls
    // (e.g. encrypt/decrypt → saveSessionToKeychain).
    let coreLock = NSRecursiveLock()

    /// Set to true when the orchestrator is initialized fresh (no CFE state found).
    /// In this case next_otpk_id resets to 1,000,000, so any OTPKs the server holds
    /// from a previous session have different key material for overlapping IDs.
    /// The next OTPK upload MUST use replaceExisting=true to wipe stale server keys.
    var needsFullOtpkReplacement: Bool {
        get { withCoreLock { needsFullOtpkReplacementStorage } }
        set { withCoreLock { needsFullOtpkReplacementStorage = newValue } }
    }
    private var needsFullOtpkReplacementStorage = false

    func clearNeedsFullOtpkReplacement() {
        needsFullOtpkReplacement = false
    }

    /// Guards against calling restoreRecentSessions() more than once per process lifetime.
    private var hasRestoredSessions: Bool {
        get { withCoreLock { hasRestoredSessionsStorage } }
        set { withCoreLock { hasRestoredSessionsStorage = newValue } }
    }
    private var hasRestoredSessionsStorage = false

    // MARK: - Session Archive
    let archiveManager = SessionArchiveManager()
    let messageCrypto = MessageCryptoService()
    let sessionInitService = CryptoSessionInitializationService()
    let sessionRestoreService = SessionRestoreService()
    
    // MARK: - Prekey ID Tracking

    /// True when core was loaded from saved Keychain keys (not freshly generated).
    /// On startup the server's OTPK set may not match the restored core's state,
    /// so the startup OTPK check must replace all server keys instead of just replenishing.
    let wasRestoredFromKeychain: Bool
    
    // MARK: - Garbage Collection
    
    /// Timer for periodic archive cleanup (24 hours). Main thread only — it is created and
    /// replaced from `DispatchQueue.main` and lives on the main run loop.
    private var gcTimer: Timer?
    
    /// GC interval (24 hours)
    private let gcIntervalSeconds: TimeInterval = 24 * 60 * 60

    private init() {
        let (loadedCore, restoredFromKeychain) = coreProvider.loadCore()
        self.bootstrapCoreStorage = loadedCore
        self.wasRestoredFromKeychain = restoredFromKeychain
        // The core loaded from the key record, so the raw copies older builds kept beside it
        // have nothing left to back up: nothing reads them since 2026-09-29.
        if loadedCore != nil {
            KeychainManager.shared.deleteLegacyDeviceKeyCopies()
        }

        // Defer GC and timer to avoid accessing Core Data before stores are loaded.
        // Session restore is intentionally NOT done here — orchestratorCore is not yet
        // available. It will be triggered inside setLocalUserId() once the core is ready.
        DispatchQueue.main.async { [weak self] in
            self?.cleanupArchivedSessions()
            self?.startGarbageCollectionTimer()
        }
    }
    
    // MARK: - Garbage Collection
    
    /// Start periodic garbage collection timer (runs every 24 hours)
    private func startGarbageCollectionTimer() {
        gcTimer?.invalidate()  // Cancel existing timer if any
        
        gcTimer = Timer.scheduledTimer(withTimeInterval: gcIntervalSeconds, repeats: true) { [weak self] _ in
            Log.debug("Running periodic archive garbage collection", category: "CryptoManager")
            self?.cleanupArchivedSessions()
        }
        
        // Add to RunLoop to ensure it fires even when app is in background
        if let timer = gcTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
        
        Log.debug("Started archive GC timer (interval: 24h)", category: "CryptoManager")
    }
    
    deinit {
        // Stop GC timer on dealloc
        gcTimer?.invalidate()
        // UniFFI manages memory automatically via Arc<T>
        // No manual cleanup needed!
    }
    
    // MARK: - Device Registration

    // MARK: - Operations with this device's own keys
    //
    // The core does them; the secrets never come out. Until 2026-09-29 each caller read the key
    // (`getSigningKeyBytes`, a Keychain copy of the identity key) and did the operation in
    // CryptoKit or through a free function taking the secret.

    /// Ed25519 over `message` with the device signing key — device auth, invites.
    ///
    /// Before the orchestrator exists (device auth at launch, right after registration) the key
    /// record in the Keychain signs, through the core, so there is no path that needs the raw key.
    func signWithDeviceKey(_ message: Data) throws -> Data {
        coreLock.lock()
        defer { coreLock.unlock() }
        if let core = orchestratorCore {
            return try core.signWithDeviceKey(message: message)
        }
        // `signBundleData` is plain Ed25519 with the signing key; the name is its first use.
        if let bootstrap = _bootstrapCore {
            return try bootstrap.signBundleData(bundleDataJson: message)
        }
        guard let record = KeychainManager.shared.loadPrivateKeysData() else {
            throw CryptoManagerError.coreNotInitialized
        }
        return try signBundleDataWithKeys(keys: record, bundleDataJson: message)
    }

    /// The core a history transfer runs on. `HistorySender` / `HistoryReceiver` sign, decapsulate
    /// and derive keys inside it; nothing here hands them a key.
    func historyCore() throws -> OrchestratorCore {
        coreLock.lock()
        defer { coreLock.unlock() }
        guard let core = orchestratorCore else { throw CryptoManagerError.coreNotInitialized }
        return core
    }

    /// This device's social-recovery bundle sealed under `vaultKey`. The bundle is the backup of
    /// the device keys, so the core packs and seals them; only the ciphertext comes out.
    func sealOwnRecoveryBundle(vaultKey: Data, createdAt: Int64) throws -> Data {
        coreLock.lock()
        defer { coreLock.unlock() }
        guard let core = orchestratorCore else { throw CryptoManagerError.coreNotInitialized }
        return try core.sealOwnRecoveryBundle(vaultKey: vaultKey, createdAt: createdAt)
    }

    /// The history-file (CTHF) channel key on the receiving side, derived in the core from the
    /// identity key and the Kyber prekey — see `OrchestratorCore.historyFileChannelKey`.
    func historyFileChannelKey(senderEphPub: Data, kemKeyId: UInt32, kemCiphertext: Data, snapshotId: Data) throws -> Data {
        coreLock.lock()
        defer { coreLock.unlock() }
        guard let core = orchestratorCore else { throw CryptoManagerError.coreNotInitialized }
        return try core.historyFileChannelKey(
            senderEphPub: senderEphPub,
            kemKeyId: kemKeyId,
            kemCiphertext: kemCiphertext,
            snapshotId: snapshotId
        )
    }

    /// Open a box sealed to this device's identity key: a sender certificate, a sibling's
    /// device metadata. Throws when the box is sealed to another key.
    func openSealedToDevice(_ sealedBox: Data) throws -> Data {
        coreLock.lock()
        defer { coreLock.unlock() }
        guard let core = orchestratorCore else { throw CryptoManagerError.coreNotInitialized }
        return try core.openSealedToDevice(sealedBox: sealedBox)
    }
    
    /// Expose local public key fields for server consistency checks.
    func localBundlePublicKeys() throws -> (identityPublic: Data, signedPrekeyPublic: Data) {
        coreLock.lock()
        defer { coreLock.unlock() }
        guard let core = orchestratorCore else { throw CryptoManagerError.coreNotInitialized }
        let fields = try core.getRegistrationBundleFields()
        return (fields.identityPublic, fields.signedPrekeyPublic)
    }

    /// Generate a complete registration bundle for device-based authentication
    /// Returns the device id and the public bundle. The keys stay in the core and in the key
    /// record saved here; until 2026-09-29 the secrets were returned too, for Keychain copies.
    func generateRegistrationBundle() throws -> (deviceId: String, bundle: RegistrationBundleFields) {
        coreLock.lock()
        defer { coreLock.unlock() }
        Log.info("Generating registration bundle...", category: "CryptoManager")

        // Always generate fresh keys for registration — never reuse an existing core
        // (an old core would carry a signature computed with the previous prologue/suite_id)
        let activeCore = try createCryptoCore()
        self._bootstrapCore = activeCore

        // Persist in CFE binary format immediately (no JSON fallback)
        let cfeData = try activeCore.exportPrivateKeys()
        let saved = KeychainManager.shared.savePrivateKeys(cfeData)
        if saved {
            Log.info("Saved registration private keys (CFE) to Keychain", category: "CryptoManager")
        } else {
            Log.error("Failed to save registration private keys to Keychain", category: "CryptoManager")
        }

        // Typed bundle — bytes are bytes, no base64, no JSON
        let bundle = try activeCore.getRegistrationBundleFields()
        let identityHexPreview = bundle.identityPublic.prefix(8).map { String(format: "%02x", $0) }.joined()
        Log.debug("Registration bundle: identity=\(identityHexPreview)… suiteId=\(bundle.suiteId)", category: "CryptoManager")

        // Derive device_id from identity public key bytes directly.
        let deviceId = deriveDeviceId(identityPublicKey: bundle.identityPublic)

        Log.info("Generated registration bundle: device_id=\(deviceId)", category: "CryptoManager")
        return (deviceId, bundle)
    }

    /// The NEGOTIATED crypto suite of the session with one device — read from the
    /// Rust core (authoritative; suite 3 is negotiated, the bundle only ever says 1/2).
    /// Falls back to the Keychain copy when the session isn't loaded into the core yet.
    /// Returns 0 when no session is known at all.
    func sessionSuiteId(forDevice deviceId: String) -> UInt16 {
        guard let contactId = SessionAddressing.asDevice(deviceId) else { return 0 }
        coreLock.lock()
        let coreSuite = orchestratorCore?.getSessionSuiteId(contactId: contactId) ?? 0
        coreLock.unlock()
        if coreSuite > 0 { return coreSuite }
        return KeychainManager.shared.loadSessionSuiteId(userId: contactId) ?? 0
    }

    /// The suite a **conversation** runs at: the weakest of the suites we hold with the person's
    /// devices, ignoring devices we have no session with.
    ///
    /// The weakest and not the first, because that is what the answer is used for — the badge on
    /// the profile screen tells a reader what protects what they send, and what they send goes to
    /// every device. A person reading "suite 3" while one of their peer's two devices is on
    /// suite 1 has been told the strength of a copy, not of the conversation.
    ///
    /// 0 means we hold no session with any of them, the same as the per-device answer.
    func sessionSuiteIdAcrossDevices(ofPeer peerId: String) -> UInt16 {
        let suites = SessionAddressing.deviceIds(ofPeer: peerId)
            .map { sessionSuiteId(forDevice: $0) }.filter { $0 > 0 }
        return suites.min() ?? 0
    }

    // MARK: - Orchestrator Event Bridge

    /// Single, serialized entry point for all `OrchestratorCore.handleEvent` calls.
    ///
    /// Why: The Rust orchestrator mutates DR state (ratchets, ACK cache, healing queue).
    /// Calling it concurrently (even from different Swift Tasks) can corrupt session state
    /// and manifest as "session out of sync" without obvious triggers.
    @discardableResult
    func handleOrchestratorEvent(
        _ event: CfeIncomingEvent,
        tag: String? = nil
    ) throws -> [CfeAction] {
        if !Thread.isMainThread {
            Log.fault(
                "Orchestrator event off main thread: \(orchestratorEventSummary(event))" + (tag.map { " tag=\($0)" } ?? ""),
                category: "CryptoOrchestrator"
            )
        }

        coreLock.lock()
        defer { coreLock.unlock() }

        guard let core = orchestratorCore else {
            throw CryptoManagerError.coreNotInitialized
        }

        // Before every event, not only before an open: an unread message is answered with a
        // DECRYPTION_ERROR only to a writer whose certificate the core can check, and the answer
        // may be decided on the message or on the ACK lookup that follows it. Handed over only in
        // `openReceiving`, a process that had opened no receiving session answered
        // `decrypt_failed` instead, and the writer never learned (TODO 80, stand 2026-09-30).
        handOverTrustedServerKeys(to: core)
        let actions = try core.handleEvent(event: event)
        logOrchestratorEvent(event, actions: actions, tag: tag)
        return actions
    }

    // MARK: - Key Management

    /// Wipes orchestrator coordination state and E2EE session archives before generating
    /// fresh device-link keys. Does not delete registration private keys (CFE).
    func prepareForDeviceLink() {
        withCoreLock {
            orchestratorCore = nil
            _bootstrapCore = nil
            hasRestoredSessions = false
        }
        KeychainManager.shared.deleteData(forKey: Self.orchestratorStateCFEKey)
        KeychainManager.shared.deleteAllE2EESessions()
        KeychainManager.shared.deleteOtpks()
        // Kyber prekeys belong to the identity being replaced, like the classic OTPKs above.
        KeychainManager.shared.deleteKyberPrekeys()
        // The new identity hasn't published a hybrid PQ key yet — drop the previous identity's
        // published flag so SPK rotation doesn't attach a hybrid signature the server can't verify.
        HybridIdentityService.resetPublishState()
        KyberPrekeyService.resetPublishState()
        Log.info("Prepared clean crypto state for device link", category: "CryptoManager")
    }

    /// Clears persisted orchestrator state so a newly linked device does not inherit
    /// ACK/healing/session metadata from a previous identity on this machine.
    func resetOrchestratorStateForDeviceLink() {
        withCoreLock {
            orchestratorCore = nil
            _bootstrapCore = nil
            hasRestoredSessions = false
        }
        KeychainManager.shared.deleteData(forKey: Self.orchestratorStateCFEKey)
        KeychainManager.shared.deleteAllE2EESessions()
        Log.info("Reset orchestrator state for fresh device link", category: "CryptoManager")
    }

    /// Delete all saved cryptographic keys and sessions (e.g., on account deletion)
    /// After calling this, the app will generate fresh keys on next registration
    func deleteAllCryptoKeys() {
        Log.info("Deleting all cryptographic data from Keychain...", category: "CryptoManager")

        // Nullify in-memory cores so next registration generates a fresh keypair. Only these
        // three under the lock: `MlsStoreManager.reset()` below takes its own lock, and
        // `MlsStoreManager` takes that one before `coreLock` — holding `coreLock` across it would
        // invert the order.
        withCoreLock {
            orchestratorCore = nil
            _bootstrapCore = nil
            hasRestoredSessions = false
        }

        // Delete private keys JSON (identity, signed prekey, signing key)
        KeychainManager.shared.deletePrivateKeys()

        // Delete all individual keys and ALL sessions
        KeychainManager.shared.deleteAllKeys()
        KeychainManager.shared.deleteOtpks()
        KeychainManager.shared.deleteKyberPrekeys()
        KeychainManager.shared.deleteData(forKey: Self.orchestratorStateCFEKey)
        // What builds before PQXDH v2 kept outside the core: the ML-KEM-768 SPK triple and the
        // deferred-contribution snapshot. Nothing reads them any more; a fresh identity must not
        // inherit them either (ghost-identity audit, 2026-07-26).
        KyberPrekeyService.deleteLegacyItems()
        // The heal queue this app kept for itself, gone 2026-09-23 with the second
        // `RustHealingQueue`. The blob is still deleted because a build that predates the change
        // may have written one, and a stale queue restored onto a fresh identity is the
        // ghost-identity audit of 2026-07-26. The core's own queue goes with `forgetContactState`
        // / the orchestrator state this teardown already clears.
        KeychainManager.shared.deleteData(forKey: "construct.healing_queue_state")

        // MLS store is signed by the identity key being deleted — a fresh identity
        // can never operate the old groups, so drop the snapshot with the keys.
        MlsStoreManager.shared.reset()

        Log.info("All cryptographic keys and sessions deleted from Keychain", category: "CryptoManager")
        Log.info("On next app launch, fresh cryptographic keys will be generated", category: "CryptoManager")
    }

    // MARK: - Registration

        // MARK: - Session Management

    /// Initializes a secure session with a recipient using the Rust core.
    func initializeSession(for userId: String, bundle: PublicKeyBundleData, withoutOneTimePrekey: Bool = false, allowStale: Bool = false) throws {
        do {
            try sessionInitService.initializeSession(
                for: userId,
                bundle: bundle,
                withoutOneTimePrekey: withoutOneTimePrekey,
                allowStale: allowStale,
                core: orchestratorCore,
                archiveSession: { [weak self] deviceId, reason in
                    Log.info("Existing session found for \(deviceId) - archiving before reinitialization to prevent desync", category: "CryptoManager")
                    self?.archiveSession(for: deviceId, reason: reason)
                },
                saveSession: { [weak self] deviceId in
                    self?.saveSessionToKeychain(forDevice: deviceId)
                }
            )
            Log.info("Session initialized for user: \(userId)", category: "CryptoManager")
        } catch let sessionError as SessionError {
            throw sessionError
        } catch CryptoManagerError.invalidKeyData {
            Log.error("Failed to decode base64-encoded keys from bundle", category: "CryptoManager")
            throw CryptoManagerError.invalidKeyData
        } catch CryptoManagerError.sessionInitializationFailed {
            Log.error("Failed to initialize session", category: "CryptoManager")
            throw CryptoManagerError.sessionInitializationFailed
        } catch {
            Log.error("Unexpected error initializing session: \(error)", category: "CryptoManager")
            throw CryptoManagerError.sessionInitializationFailed
        }
    }

    /// Record the signed-in account and give the crypto core our identity.
    ///
    /// `userId` is the server-assigned account UUID and is kept for routing and storage; what
    /// reaches the core is this **device's** id, because that is what the peer will name us by.
    /// See `cryptoLocalUserId`.
    func setLocalUserId(_ userId: String) {
        // Whole body: the check for an existing core and the creation of one must not interleave
        // with another caller's, or two cores are built and one replaces the other.
        coreLock.lock()
        defer { coreLock.unlock() }
        _cachedUserId = userId
        let cryptoId = cryptoLocalUserId

        // An empty identity would go straight into the AD of every session this device opens, and
        // the failure is invisible until the peer cannot decrypt. The device id is written to the
        // Keychain before the registration RPC is even attempted, so an empty one here means the
        // Keychain is unreadable — a state in which no session should be established at all.
        guard !cryptoId.isEmpty else {
            Log.fault("setLocalUserId: no device id — refusing to give the core an empty identity", category: "CryptoManager")
            return
        }

        if let existing = orchestratorCore {
            existing.setLocalUserId(userId: cryptoId)
            migrateSessionsIfNeeded(core: existing)
            Log.debug("CryptoManager: local identity = device \(cryptoId.prefix(8))…", category: "CryptoManager")
            return
        }

        // Build OrchestratorCore from Keychain or bootstrap core keys.
        let keysData: Data?
        if let d = KeychainManager.shared.loadPrivateKeysData() {
            keysData = d
        } else if let bootstrapData = try? _bootstrapCore?.exportPrivateKeys() {
            keysData = bootstrapData
        } else {
            Log.error("setLocalUserId: no keys available to create OrchestratorCore", category: "CryptoManager")
            return
        }

        guard let keys = keysData else { return }

        do {
            let newCore = try createOrchestratorCoreFromKeys(keysData: keys, myUserId: cryptoId)
            // Import OTPKs if available
            if let otpksData = KeychainManager.shared.loadOtpksData() {
                do {
                    try newCore.importOneTimePrekeys(data: otpksData)
                    Log.debug("Imported OTPKs into OrchestratorCore (\(newCore.oneTimePrekeyCount()) keys)", category: "CryptoManager")
                } catch {
                    // See reloadCoreFromKeychain: a silent empty OTPK store + high next_otpk_id +
                    // stale server keys is the seed of the session-init reset storm. Force a single
                    // consistent replace-all instead of swallowing the failure.
                    Log.fault("Failed to import OTPKs into OrchestratorCore — forcing full OTPK replacement: \(error)", category: "CryptoManager")
                    needsFullOtpkReplacement = true
                }
            } else {
                Log.info("No OTPKs found in Keychain — key_manager will have empty OTPK store", category: "CryptoManager")
            }
            // Restore the Kyber prekeys. A blob that will not import leaves the core without the
            // one-time keys the server still serves, and the next ids it issues collide with
            // theirs — the same state a lost classic OTPK blob is, with the same repair.
            if !KyberPrekeyService.restore(into: newCore) {
                needsFullOtpkReplacement = true
            }
            // Restore ACK cache, healing queue, and init locks.
            loadOrchestratorStateCFE(into: newCore)
            migrateSessionsIfNeeded(core: newCore)
            orchestratorCore = newCore
            _bootstrapCore = nil
            Log.debug("CryptoManager: OrchestratorCore created (userId=\(cryptoId.prefix(8))…)", category: "CryptoManager")
            // Session restore was skipped in init() because orchestratorCore was not yet
            // available. Now that the core is ready, restore sessions on the next run loop
            // tick (Core Data is guaranteed to be loaded by this point).
            if !hasRestoredSessions {
                hasRestoredSessions = true
                Task { @MainActor [weak self] in
                    self?.restoreRecentSessions(limit: 10)
                }
            }
        } catch {
            Log.error("setLocalUserId: OrchestratorCore init failed: \(error)", category: "CryptoManager")
        }
    }

    /// One-time migration: sessions saved before the AD fix (build < 350) stored
    /// `local_user_id` as a 32-char device-hash instead of the server UUID.  Those
    /// sessions can never decrypt correctly.  On first launch with the fixed code we
    /// wipe all persisted sessions so fresh X3DH handshakes establish correct AD.
    private func migrateSessionsIfNeeded(core: OrchestratorCore) {
        let migrationKey = "construct.adMigration.serverUUID.v1.done"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }
        let contactIds = core.getAllSessionContactIds()
        for contactId in contactIds {
            // These come from `getAllSessionContactIds()`, so they already name devices.
            _ = core.removeSession(contactId: contactId)
            KeychainManager.shared.deleteSession(for: contactId)
        }
        if !contactIds.isEmpty {
            Log.info("AD migration: cleared \(contactIds.count) stale session(s) with wrong local_user_id — fresh handshakes will use server UUID", category: "CryptoManager")
        }
        UserDefaults.standard.set(true, forKey: migrationKey)
    }

    // MARK: - Key Diagnostics

    /// Log local public key prefixes for post-mortem analysis when session init fails.
    /// Allows comparing with what the server served to the INITIATOR.
    func logLocalKeyDiagnostics() {
        guard let core = orchestratorCore else { return }
        do {
            let fields = try core.getRegistrationBundleFields()
            func hexPrefix(_ bytes: Data) -> String {
                bytes.prefix(8).map { String(format: "%02x", $0) }.joined()
            }
            let ik = hexPrefix(fields.identityPublic)
            let spk = hexPrefix(fields.signedPrekeyPublic)
            let vk = hexPrefix(fields.verifyingKey)
            Log.error("LOCAL KEY DIAGNOSTICS — identity=\(ik)… spk=\(spk)… vk=\(vk)…", category: "CryptoManager")
        } catch {
            Log.error("LOCAL KEY DIAGNOSTICS: export failed: \(error)", category: "CryptoManager")
        }
    }

}
