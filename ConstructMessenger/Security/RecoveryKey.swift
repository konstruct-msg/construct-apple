//
//  RecoveryKey.swift
//  Construct Messenger
//
//  The account's recovery key, as the core makes it from the phrase: hybrid Ed25519 + ML-DSA-65
//  since construct-core 0.59.0. The Ed25519 half is the key accounts always had — the account's
//  address — so a phrase written down before keeps its key, its address and its fingerprint.
//
//  The core signs; this app never holds the private key. The bytes signed are
//  `construct_server_trust::recovery`'s: a setup names the account, a claim names the device it
//  hands the account to. From 2026-11-01 the server takes nothing else.
//  construct-docs todo/222-recovery-key-hybrid-pq.md
//

import Foundation

enum RecoveryKey {

    /// A hybrid public key and its signature over one recovery message.
    struct Signed {
        /// Ed25519 (32) ‖ ML-DSA-65 (1952).
        let publicKey: Data
        let signature: Data
        let timestamp: Int64

        /// The account's address: the key's Ed25519 half.
        var address: Data { RecoveryKey.address(of: publicKey) }
    }

    /// The Ed25519 half of a hybrid recovery key — what `AccountAddress` keeps.
    static func address(of hybridKey: Data) -> Data {
        Data(hybridKey.prefix(AccountAddress.length))
    }

    /// The address the phrase determines.
    static func address(phrase: String) throws -> Data {
        address(of: try recoveryPublicKey(mnemonic: phrase))
    }

    /// The phrase's key signing its setup on `accountId` — or the upgrade of the Ed25519 key the
    /// account already has, which is the same message.
    static func setup(phrase: String, accountId: String, at date: Date = Date()) throws -> Signed {
        let timestamp = Int64(date.timeIntervalSince1970)
        let signed = try signRecoverySetup(mnemonic: phrase, accountId: accountId, timestamp: timestamp)
        return Signed(publicKey: signed.publicKey, signature: signed.signature, timestamp: timestamp)
    }

    /// The phrase's key handing its account to the device these keys name.
    static func claim(
        phrase: String,
        deviceId: String,
        verifyingKey: Data,
        identityPublic: Data,
        at date: Date = Date()
    ) throws -> Signed {
        let timestamp = Int64(date.timeIntervalSince1970)
        let signed = try signRecoveryClaim(
            mnemonic: phrase,
            timestamp: timestamp,
            deviceId: deviceId,
            verifyingKey: verifyingKey,
            identityPublic: identityPublic
        )
        return Signed(publicKey: signed.publicKey, signature: signed.signature, timestamp: timestamp)
    }
}
