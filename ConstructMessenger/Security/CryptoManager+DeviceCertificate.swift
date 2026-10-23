//
//  CryptoManager+DeviceCertificate.swift
//  Construct Messenger
//
//  Devices of one account vouch for each other: the link side.
//  `construct-docs/decisions/devices-of-an-account-sign-each-other.md`.
//
//  The core signs only keys the link QR names, so both ends act at link time:
//  - the new device needs its hybrid identity key *before* the QR is shown or scanned —
//    the QR fingerprint (Flow B) and the proof of keys (Flow A) cover it;
//  - the old device issues the certificate from what the QR showed and the directory serves.
//

import Foundation

/// What a device about to be linked shows of its keys.
struct LinkIdentity {
    let identityPublic: Data
    let hybridPublic: Data
    /// Flow A: the answer to the secret in the old device's QR. nil when no secret was given.
    let keyProof: Data?
}

extension CryptoManager {

    /// On the new device, after `generateRegistrationBundle`: make sure the hybrid identity key
    /// exists and is saved with the other keys, and answer the old device's QR secret.
    ///
    /// Until device certificates the hybrid key was created after the link, on the orchestrator
    /// the account brings up. Nothing on that orchestrator depends on the account, only on this
    /// device's id, so a throwaway one is built from the saved keys here; the key it creates is
    /// saved before anything about it is shown, and the orchestrator brought up after the link
    /// loads it from the same record — `HybridIdentityService` then publishes this key, not a
    /// new one.
    func prepareLinkIdentity(linkSecret: Data?) throws -> LinkIdentity {
        coreLock.lock()
        defer { coreLock.unlock() }

        guard let keys = KeychainManager.shared.loadPrivateKeysData(),
              let deviceId = KeychainManager.shared.loadDeviceID(), !deviceId.isEmpty
        else { throw CryptoManagerError.coreNotInitialized }

        let core = try createOrchestratorCoreFromKeys(keysData: keys, myUserId: deviceId)
        let hybrid = try core.ensureHybridSignatureKey()
        // A key that exists only in memory must not be shown: the next launch would load a core
        // without it and generate a different one, and the old device would have vouched for a
        // key this device can never prove (same rule as `ensureHybridIdentityPublicKey`).
        guard KeychainManager.shared.savePrivateKeys(try core.exportPrivateKeys()) else {
            throw CryptoManagerError.keyStatePersistFailed
        }
        let identity = try core.getRegistrationBundleFields().identityPublic
        let proof = try linkSecret.map { try core.deviceLinkKeyProof(secret: $0) }
        return LinkIdentity(identityPublic: identity, hybridPublic: hybrid, keyProof: proof)
    }

    /// On the old device: vouch for `subject`, a device being linked to this account. The core
    /// refuses (`EvidenceMismatch`) unless `evidence` — what the link QR showed — names exactly
    /// these keys.
    func issueDeviceCertificate(subject: DeviceCertKeys, evidence: DeviceLinkEvidence) throws -> Data {
        // The signer's hybrid key: every registered device has published one, but the core signs
        // only with a key it holds, so make sure it is loaded.
        _ = try ensureHybridIdentityPublicKey()
        coreLock.lock()
        defer { coreLock.unlock() }
        guard let core = orchestratorCore else { throw CryptoManagerError.coreNotInitialized }
        return try core.issueDeviceCertificate(subject: subject, evidence: evidence)
    }

    /// The core's verdict on each device the server lists for one account, given the devices of
    /// that account this client already trusts. nil before the core is up — nothing is judged then,
    /// and nothing is alarmed.
    func judgePeerDevices(trustedDeviceIds: [String], offered: [OfferedPeerDevice]) -> [PeerDeviceVerdict]? {
        coreLock.lock()
        defer { coreLock.unlock() }
        guard let core = orchestratorCore else { return nil }
        return core.judgePeerDevices(trustedDeviceIds: trustedDeviceIds, offered: offered)
    }
}
