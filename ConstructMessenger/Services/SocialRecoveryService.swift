//
//  SocialRecoveryService.swift
//  ConstructMessenger
//
//  SLIP-39 social recovery — Variant A (vault key Shamir splitting).
//  All UniFFI calls are stubbed until the xcframework is rebuilt with the new Rust functions.
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

    // MARK: - Recovery state

    enum RecoveryStep: Equatable {
        case idle
        case enterShares
        case reconstructing
        case done
        case failed(String)
    }

    // MARK: - Published state

    var setupStep: SetupStep = .idle
    var recoveryStep: RecoveryStep = .idle

    var threshold: Int = 2
    var shareCount: Int = 3
    var shares: [String] = []
    var shareLabels: [String] = []
    var distributedFlags: [Bool] = []

    var enteredShares: [String] = []

    var isConfigured: Bool = false

    // MARK: - Setup

    func configure(threshold: Int, shareCount: Int) {
        self.threshold = threshold
        self.shareCount = shareCount
        setupStep = .configure
    }

    func generateShares() {
        // TODO: wire to UniFFI after xcframework rebuild
        // let vaultKey = sr_generate_vault_key()
        // shares = sr_create_recovery_shares(vaultKey: vaultKey, threshold: UInt8(threshold), shareCount: UInt8(shareCount))
        shares = (0..<shareCount).map { i in
            placeholderMnemonic(shareIndex: i)
        }
        shareLabels = Array(repeating: "", count: shareCount)
        distributedFlags = Array(repeating: false, count: shareCount)
        setupStep = .displayShare(index: 0)
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
        // TODO: wire to UniFFI after xcframework rebuild
        // let bundle = SrRecoveryBundle(...)
        // let sealed = sr_seal_recovery_bundle(vaultKey: vaultKey, bundle: bundle)
        // upload sealed to server
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        isConfigured = true
        setupStep = .done
    }

    // MARK: - Recovery

    func addEnteredShare(_ mnemonic: String) {
        let trimmed = mnemonic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        enteredShares.append(trimmed)
    }

    func removeEnteredShare(at index: Int) {
        guard index < enteredShares.count else { return }
        enteredShares.remove(at: index)
    }

    func reconstructAndRestore() async {
        recoveryStep = .reconstructing
        // TODO: wire to UniFFI after xcframework rebuild
        // let vaultKey = sr_reconstruct_vault_key(mnemonics: enteredShares)
        // let ciphertext = download recovery bundle from server
        // let bundle = sr_open_recovery_bundle(vaultKey: vaultKey, ciphertext: ciphertext)
        // restore bundle.deviceSigningKey, bundle.deviceIdentityKey, bundle.deviceId
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        recoveryStep = .done
    }

    // MARK: - Reset

    func reset() {
        setupStep = .idle
        recoveryStep = .idle
        shares = []
        shareLabels = []
        distributedFlags = []
        enteredShares = []
        threshold = 2
        shareCount = 3
    }

    // MARK: - Private helpers

    /// Returns 28-word placeholder mnemonic for stub usage.
    private func placeholderMnemonic(shareIndex: Int) -> String {
        let wordBank = [
            "academic", "acid", "acrobat", "adapt", "again", "agency", "agree", "alarm",
            "album", "alert", "algebra", "alive", "alpha", "already", "alto", "alumni",
            "always", "amber", "amend", "amount", "angel", "angry", "animal", "answer",
            "apart", "appear", "apple", "arena"
        ]
        return wordBank.shuffled().prefix(28).joined(separator: " ")
    }
}
