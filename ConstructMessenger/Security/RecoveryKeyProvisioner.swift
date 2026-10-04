//
//  RecoveryKeyProvisioner.swift
//  Construct Messenger
//
//  Makes the account's recovery key without a screen. The key is the account's address, and
//  until 2026-10-04 it existed only once the person had sat through twelve words and a quiz —
//  so the first thing a new account met when it reached for an invite was that wall.
//  `decisions/recovery-key-backup-is-deferred-not-skipped.md`.
//
//  Order is the point: the phrase is in the vault before the server hears of the key, so there
//  is never a key on the server whose phrase exists nowhere. A retry uses the stored phrase, not a
//  new one, and the server accepts the same key twice (construct-server `e53c0ee`).
//

import Foundation
import GRPCCore

@MainActor
final class RecoveryKeyProvisioner {

    enum Outcome: Equatable {
        /// This device knows the address already; nothing to do.
        case alreadyKnown
        /// The account has a key this device has not seen (set up on another device, or another
        /// device of the account won a race). The gate's confirm path covers it.
        case setElsewhere
        /// Created and accepted; the phrase waits in the vault for its copy.
        case provisioned
        /// No passcode on this device, so nothing can wait safely: the visible setup runs now.
        case needsVisibleSetup
        /// The server could not be reached or refused for a passing reason. A pending phrase, if
        /// one was made, stays for the next attempt.
        case deferred
    }

    struct Dependencies {
        var knownAddress: () -> Data?
        /// Whether the server holds a key for the account. Throws when it cannot be asked.
        var serverHasKey: () async throws -> Bool
        var generatePhrase: () throws -> String
        /// Derives, signs and calls `SetRecoveryKey`; returns the public key on success.
        var upload: (_ phrase: String, _ userId: String) async throws -> Data
        /// True when the server refused because another key is set.
        var isOtherKeySet: (Error) -> Bool
        var rememberAddress: (Data) -> Void
        var store: RecoveryPhraseStore
    }

    static let shared = RecoveryKeyProvisioner(dependencies: .live)

    private let dependencies: Dependencies
    private var running: Task<Outcome, Never>?

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// Idempotent and single-flight: a launch and the end of onboarding may both ask.
    func ensureKey(userId: String) async -> Outcome {
        if let running { return await running.value }
        let task = Task { await run(userId: userId) }
        running = task
        let outcome = await task.value
        running = nil
        return outcome
    }

    private func run(userId: String) async -> Outcome {
        let d = dependencies
        if d.knownAddress() != nil { return .alreadyKnown }

        // A phrase made on an earlier launch whose upload never got an answer goes first, before
        // anything is asked: the server may already hold its key.
        var phrase = d.store.pendingPhrase(account: userId)
        if phrase == nil {
            do {
                if try await d.serverHasKey() { return .setElsewhere }
            } catch {
                Log.info("Recovery key: status unavailable (\(error.localizedDescription)) — later", category: "Recovery")
                return .deferred
            }
            guard d.store.canHold else { return .needsVisibleSetup }
            do {
                let made = try d.generatePhrase()
                guard d.store.storePending(made, account: userId) else {
                    Log.error("Recovery key: could not store the pending phrase — visible setup", category: "Recovery")
                    return .needsVisibleSetup
                }
                phrase = made
            } catch {
                Log.error("Recovery key: phrase generation failed: \(error)", category: "Recovery")
                return .deferred
            }
        }
        guard let phrase else { return .deferred }

        let publicKey: Data
        do {
            publicKey = try await d.upload(phrase, userId)
        } catch where d.isOtherKeySet(error) {
            // Not ours, and never will be: the phrase names nothing.
            d.store.forgetPending()
            Log.info("Recovery key: another key is set for the account — pending phrase dropped", category: "Recovery")
            return .setElsewhere
        } catch {
            Log.info("Recovery key: upload deferred (\(error.localizedDescription))", category: "Recovery")
            return .deferred
        }

        d.rememberAddress(publicKey)
        if !d.store.promotePending(account: userId) {
            // The key is set and the address known, but the phrase could not move behind
            // authentication. It stays pending — readable, never lost — and the next run retries.
            Log.error("Recovery key: set, but the phrase could not be held — left pending", category: "Recovery")
        }
        Log.info("Recovery key: created and set; copy pending", category: "Recovery")
        return .provisioned
    }
}

extension RecoveryKeyProvisioner.Dependencies {
    static var live: Self {
        Self(
            knownAddress: { AccountAddress.own() },
            serverHasKey: { try await AuthServiceClient.shared.getRecoveryStatus().isSetup },
            generatePhrase: { try generateMnemonic(wordCount: 12) },
            upload: { phrase, userId in
                let seed = try mnemonicToSeed(mnemonic: phrase)
                let keypair = try deriveRecoveryKeypair(seed: seed)
                let timestamp = Int64(Date().timeIntervalSince1970)
                let signature = try signRecoveryChallenge(
                    privateKey: keypair.privateKey,
                    message: "CONSTRUCT_RECOVERY_SETUP:\(userId):\(timestamp)"
                )
                _ = try await AuthServiceClient.shared.setRecoveryKey(
                    publicKey: keypair.publicKey,
                    signature: Data(signature),
                    timestamp: timestamp
                )
                return keypair.publicKey
            },
            isOtherKeySet: { ($0 as? RPCError)?.code == .alreadyExists },
            rememberAddress: { AccountAddress.rememberOwn($0) },
            store: RecoveryPhraseVault.shared
        )
    }
}
