//
//  SocialRecoveryService.swift
//  ConstructMessenger
//
//  SLIP-39 social recovery — Variant A (vault key Shamir splitting).
//
//  Setup only. The restore half (`reconstructAndRestore`) stood here until 2026-09-29 with no
//  screen reaching it, and what it did was write the bundle's keys into Keychain copies the core
//  never loads from — a restore that restored nothing. A real one needs a core call that turns
//  the bundle into a key record; the uploaded format is unchanged, so bundles made before then
//  stay openable when it exists.
//

import Foundation

@MainActor
@Observable
final class SocialRecoveryService {

    // MARK: - Setup state

    enum SetupStep: Equatable {
        case idle
        case configure
        case displayShare(index: Int)
        case uploading
        case done
        case failed(String)
    }

    // MARK: - Published state

    var setupStep: SetupStep = .idle

    var threshold: Int = 2
    var shareCount: Int = 3
    var shares: [String] = []
    var shareLabels: [String] = []
    var distributedFlags: [Bool] = []

    var isConfigured: Bool = false

    // Vault key held in memory only during the setup flow; cleared after upload.
    private var vaultKey = Data()

    // MARK: - Setup

    func configure(threshold: Int, shareCount: Int) {
        self.threshold = threshold
        self.shareCount = shareCount
        setupStep = .configure
    }

    func generateShares() {
        do {
            vaultKey = try srGenerateVaultKey()
            let mnemonics = try srCreateRecoveryShares(
                vaultKey: vaultKey,
                threshold: UInt8(threshold),
                shareCount: UInt8(shareCount)
            )
            shares = mnemonics
            shareLabels = Array(repeating: "", count: shareCount)
            distributedFlags = Array(repeating: false, count: shareCount)
            setupStep = .displayShare(index: 0)
        } catch {
            setupStep = .failed(error.localizedDescription)
        }
    }

    func setLabel(_ label: String, forShare index: Int) {
        guard index < shareLabels.count else { return }
        shareLabels[index] = label
    }

    func markShareDistributed(index: Int) {
        guard index < shareCount else { return }
        distributedFlags[index] = true
        let next = index + 1
        if next < shareCount {
            setupStep = .displayShare(index: next)
        } else {
            setupStep = .uploading
            Task { await uploadBundle() }
        }
    }

    func uploadBundle() async {
        guard !vaultKey.isEmpty else {
            setupStep = .failed("vault key missing")
            return
        }
        do {
            // The core packs its own keys and seals them; only the ciphertext comes out.
            let ciphertext = try CryptoManager.shared.sealOwnRecoveryBundle(
                vaultKey: vaultKey,
                createdAt: Int64(Date().timeIntervalSince1970)
            )
            try await AuthServiceClient.shared.storeRecoveryBundle(ciphertext: ciphertext)
            vaultKey = Data()  // drop after a successful upload
            isConfigured = true
            setupStep = .done
        } catch {
            setupStep = .failed(error.localizedDescription)
        }
    }

    // MARK: - Reset

    func reset() {
        setupStep = .idle
        shares = []
        shareLabels = []
        distributedFlags = []
        threshold = 2
        shareCount = 3
        vaultKey = Data()
    }
}
