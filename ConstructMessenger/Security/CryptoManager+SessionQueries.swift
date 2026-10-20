//
//  CryptoManager+SessionQueries.swift
//  Construct Messenger
//
//  Session queries and envelope helpers: hasSession family, seal/open
//  envelope and first flight, receiving opens, certificate and KT checks.
//
//  Moved verbatim out of CryptoManager.swift (TODO 184); behaviour unchanged.
//

import Foundation
import CoreData
import os.log

extension CryptoManager {

    /// Whether the core holds a live ratchet with **one device**.
    ///
    /// Takes a device id: a ratchet is between two devices, so "do we have a session with this
    /// person" is a different question and has its own name below. Until step 6 this resolved an
    /// account to the pinned device and answered about that one, which read as the whole person —
    /// a peer whose second device had a session and whose first did not was reported sessionless,
    /// and the paths that act on "no session" are the destructive ones.
    func hasSession(for deviceId: String) -> Bool {
        guard let contactId = SessionAddressing.asDevice(deviceId) else { return false }
        return orchestratorCore?.hasSession(contactId: contactId) ?? false
    }

    /// Whether we hold a live ratchet with **any** device of a person.
    ///
    /// The account-shaped question, and the one every "is this chat ready", "may I encrypt",
    /// "should I prewarm" gate is actually asking. It folds the set with `contains` rather than
    /// picking a device, so nothing downstream inherits a choice nobody made.
    ///
    /// A caller that then *acts* on one session must name which device it means; this answers
    /// only whether there is anything to act on.
    func hasSessionWithAnyDevice(ofPeer peerId: String) -> Bool {
        SessionAddressing.deviceIds(ofPeer: peerId).contains { hasSession(for: $0) }
    }

    /// Whether session state exists for `userId` **anywhere** — loaded in the core, or on disk.
    ///
    /// `hasSession(for:)` answers only the first, because that is what "can I encrypt right now"
    /// needs. Teardown needs the other question: a contact nobody has messaged this run has its
    /// session in the Keychain and not in the core, so a delete guarded on `hasSession` archived
    /// nothing and left the entry behind — where the next invite redeem imported it and encrypted
    /// with a ratchet the peer had already thrown away (2026-08-17).
    ///
    /// Ask this one wherever the question is "is there anything here to put away", never the
    /// other one.
    func hasStoredSessionState(for deviceId: String) -> Bool {
        guard let contactId = SessionAddressing.asDevice(deviceId) else { return false }
        if orchestratorCore?.hasSession(contactId: contactId) == true { return true }
        return KeychainManager.shared.loadSessionData(for: contactId) != nil
    }

    /// True once the OrchestratorCore exists. Before this, `hasSession(for:)` returns
    /// false for *every* contact, so any "session missing → END_SESSION / re-init"
    /// decision (e.g. prewarm) MUST be gated on this. Otherwise, during the startup
    /// window — especially when auth is delayed by a token refresh — a healthy session
    /// that simply hasn't been restored yet looks missing and gets destroyed.
    var isCoreReady: Bool {
        return orchestratorCore != nil
    }

    /// Restore-aware variant of `hasSession`. If the core currently has no session for
    /// `userId`, it attempts a lazy import from Keychain before answering. This closes a
    /// startup race where prewarm runs after the core is created but before
    /// `restoreRecentSessions` has imported the on-disk session — which otherwise looks
    /// like a missing session and triggers a destructive END_SESSION + fresh re-init,
    /// discarding the ratchet and breaking decryption of the peer's in-flight messages.
    func hasOrRestoreSession(for deviceId: String) -> Bool {
        guard isCoreReady else { return false }
        return restoreSession(for: deviceId)
    }

    /// Restore-aware `hasSessionWithAnyDevice`: the same fold, with the lazy Keychain import each
    /// device gets from `restoreSession`.
    func hasOrRestoreSessionWithAnyDevice(ofPeer peerId: String) -> Bool {
        guard isCoreReady else { return false }
        return SessionAddressing.deviceIds(ofPeer: peerId).contains { restoreSession(for: $0) }
    }

    /// Seal a wire payload just encrypted for `deviceId` as a session envelope, or `nil` when it
    /// must go with a certificate: the session's first flight (the peer cannot find a tag yet),
    /// or a session made before the envelope. The core decides
    /// (`decisions/sealed-envelope-keyed-by-the-session.md`).
    func sealEnvelope(forDevice deviceId: String, wirePayload: Data) -> Data? {
        coreLock.lock()
        defer { coreLock.unlock() }
        guard let core = orchestratorCore, let contactId = SessionAddressing.asDevice(deviceId) else {
            return nil
        }
        return core.sealEnvelope(contactId: contactId, wirePayload: wirePayload)
    }

    /// Who wrote a session envelope, found by its tag, and its opened body; `nil` when no pair this
    /// device holds matches.
    func openEnvelope(_ envelope: Data) -> EnvelopeOpened? {
        coreLock.lock()
        defer { coreLock.unlock() }
        return orchestratorCore?.openEnvelope(envelope: envelope)
    }

    /// Seal a first flight — a wire payload written on a session `deviceId` has not answered yet —
    /// whole, with the sender certificate, under the handshake's hybrid key
    /// (`decisions/first-flight-sealed-whole.md`). `nil` when the payload is not a first flight: it
    /// goes with a certificate. Throws for a first flight that cannot be sealed, which must not go
    /// any other way — its header names the sender.
    func sealFirstFlight(
        forDevice deviceId: String,
        recipientIdentityKey: Data,
        wirePayload: Data,
        certificate: Data
    ) throws -> Data? {
        coreLock.lock()
        defer { coreLock.unlock() }
        guard let core = orchestratorCore else { throw CryptoManagerError.coreNotInitialized }
        guard let contactId = SessionAddressing.asDevice(deviceId) else {
            throw CryptoManagerError.invalidKeyData
        }
        return try core.sealFirstFlight(
            contactId: contactId,
            recipientIdentity: recipientIdentityKey,
            wirePayload: wirePayload,
            certificate: certificate
        )
    }

    /// Open a `SealedInner.first_flight` sealed to this device: the certificate and the wire
    /// payload, as a first message always carried them.
    func openFirstFlight(_ sealed: Data) throws -> FirstFlightOpened {
        coreLock.lock()
        defer { coreLock.unlock() }
        guard let core = orchestratorCore else { throw CryptoManagerError.coreNotInitialized }
        return try core.openFirstFlight(sealed: sealed)
    }

    /// How late messages have arrived since launch (PQR-4) — `nil` before the core is up.
    func reorderStats() -> ReorderStats? {
        orchestratorCore?.reorderStats()
    }

    /// Return a read-only health snapshot for the session with one device.
    /// Returns `nil` if no session exists or the core is not initialized.
    func getSessionHealth(for deviceId: String) -> SessionHealthReport? {
        guard let contactId = SessionAddressing.asDevice(deviceId) else { return nil }
        return orchestratorCore?.getSessionHealth(contactId: contactId)
    }

    /// The identity of the session with `userId` — see `SessionEpoch`.
    ///
    /// The single reader of the core's session identifier. Every "is this still the session I
    /// decided about?" goes through here rather than through `establishedAt` timestamps: the epoch
    /// is derived from the handshake, so it is exact where a whole-second stamp was not, and it is
    /// identical on both sides, so it means the same thing across the wire.
    ///
    /// `nil` means there is no session (or the core is not ready) — never "unknown".
    func sessionEpoch(for deviceId: String) -> SessionEpoch? {
        guard let sessionId = getSessionHealth(for: deviceId)?.sessionId else { return nil }
        return SessionEpoch(rawValue: sessionId)
    }

    // MARK: - The core's queue of messages waiting for a session

    /// Open a receiving session from what the core holds under `device`. Each queued message
    /// opens with the key its own sender certificate names, once the core has checked it — nothing
    /// is fetched (`decisions/first-message-opens-without-the-server.md`). `nil` only when there is
    /// no core to ask.
    func openReceiving(device: String) -> ReceivingOpenResult? {
        coreLock.lock()
        defer { coreLock.unlock() }
        guard let core = orchestratorCore else { return nil }
        handOverTrustedServerKeys(to: core)
        return core.openReceiving(device: device)
    }

    /// The server keys a sender certificate is checked against, as this app resolves them (the
    /// well-known key and the build pins, `BundleSigningTrust`). Handed over before every open and
    /// every orchestrator event rather than once: the fetched key can arrive or rotate while the
    /// app runs, and a stale copy in the core would refuse certificates the app itself accepts.
    /// Caller holds `coreLock`.
    func handOverTrustedServerKeys(to core: OrchestratorCore, extraKeys: [Data] = []) {
        core.setTrustedServerKeys(keys: BundleSigningTrust.trustedKeyBytes() + extraKeys)
        // Delegations of the server's hybrid keys. The core keeps only those a root pinned in this
        // build signed, so where they came from does not matter; one it already holds is kept once.
        _ = core.admitServerDelegations(delegations: ServerKeyManager.cachedServerDelegations())
    }

    /// The core's verdict on a sender certificate — signature, device and age, judged as an open
    /// would (`decisions/server-keys-rooted-offline-and-hybrid.md`). Until 2026-10-03 this app
    /// checked the Ed25519 signature itself, beside the core's check, and the two disagreed on age
    /// and on the device. `nil` only when there is no core to ask. `extraKeys` is a test seam.
    func certificateVerdict(_ certificate: SenderCertificate, extraKeys: [Data] = []) -> CertificateVerdict? {
        coreLock.lock()
        defer { coreLock.unlock() }
        guard let core = orchestratorCore else { return nil }
        handOverTrustedServerKeys(to: core, extraKeys: extraKeys)
        return core.certificateVerdict(certificate: certificate)
    }

    /// The core's verdicts on a bundle's KT proofs. `nil` only when there is no core to ask.
    func verifyKtProofs(
        deviceId: String,
        identityKey: Data,
        identityProof: KtInclusionProof,
        hybridIdentityKey: Data?,
        hybridProof: KtInclusionProof?,
        treeHead: KtSignedTreeHead?
    ) -> KtVerdicts? {
        coreLock.lock()
        defer { coreLock.unlock() }
        guard let core = orchestratorCore else { return nil }
        handOverTrustedServerKeys(to: core)
        return core.verifyKtProofs(
            deviceId: deviceId,
            identityKey: identityKey,
            identityProof: identityProof,
            hybridIdentityKey: hybridIdentityKey,
            hybridProof: hybridProof,
            treeHead: treeHead
        )
    }

    /// Whether any of `devices` is opening a session with us right now (a handshake of theirs
    /// queued in the core within the last 20 s).
    func peerHandshakeHeld(devices: [String]) -> Bool {
        guard !devices.isEmpty else { return false }
        coreLock.lock()
        defer { coreLock.unlock() }
        return orchestratorCore?.peerHandshakeHeld(devices: devices) ?? false
    }

    /// How many messages the core holds waiting for a session with `deviceId`.
    func pendingMessageCount(forDevice deviceId: String) -> Int {
        coreLock.lock()
        defer { coreLock.unlock() }
        return Int(orchestratorCore?.pendingMessageCount(contactId: deviceId) ?? 0)
    }

    /// Every session we hold, by device.
    /// Every **device** we hold a ratchet with — the core's contact ids, which are
    /// `CryptoDeviceId`, never account UUIDs.
    ///
    /// Named `getAllSessionUserIds` until 2026-09-05, and three of its four callers read the
    /// result as an account because of it. One of them, `sendEndSessionToAllContacts`, fed each
    /// device id to `sendEndSession(to:)`, which resolves an account to its devices — so it found
    /// no rows and skipped every session it was asked to tear down.
    func getAllSessionDeviceIds() -> [String] {
        return orchestratorCore?.getAllSessionContactIds() ?? []
    }

    /// Open a receiving session from one message that does not wait in the core's queue — a
    /// sibling's SENDER_SYNC — with the key its sender certificate names. Returns the device the
    /// session opened with and the first message's raw bytes (KNST frame, protobuf or control
    /// string; callers decode via `ChunkedMessageReassembler.process(data:)`).
    func openReceiving(singleMessage message: ChatMessage) throws -> (device: String, plaintext: Data) {
        coreLock.lock()
        let core = orchestratorCore
        if let core { handOverTrustedServerKeys(to: core) }
        coreLock.unlock()
        do {
            return try sessionInitService.openReceiving(
                message,
                core: core,
                archiveSession: { [weak self] deviceId, reason in
                    self?.archiveSession(for: deviceId, reason: reason)
                },
                saveSession: { [weak self] deviceId in
                    self?.saveSessionToKeychain(forDevice: deviceId)
                }
            )
        } catch SessionError.notAHandshakeCarrier {
            throw SessionError.notAHandshakeCarrier
        } catch {
            Log.error("Receiving open of \(message.id.prefix(8))… failed: \(error)", category: "CryptoManager")
            logLocalKeyDiagnostics()
            throw CryptoManagerError.sessionInitializationFailed
        }
    }
}
