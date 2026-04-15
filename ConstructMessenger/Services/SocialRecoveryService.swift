//
//  SocialRecoveryService.swift
//  ConstructMessenger
//
//  SLIP-39 social recovery — Variant A (vault key Shamir splitting).
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

    // Vault key held in memory only during the setup flow; cleared after upload.
    private var vaultKey: [UInt8] = []

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
            let km = KeychainManager.shared
            guard
                let signingKey  = km.loadDeviceSigningKey(),
                let identityKey = km.loadDeviceIdentityKey(),
                let deviceId    = km.loadDeviceID()
            else {
                setupStep = .failed("device keys not found in Keychain")
                return
            }
            let bundle = SrRecoveryBundle(
                deviceSigningKey:  signingKey,
                deviceIdentityKey: identityKey,
                deviceId:          deviceId,
                createdAt:         Int64(Date().timeIntervalSince1970)
            )
            let ciphertext = try srSealRecoveryBundle(vaultKey: vaultKey, bundle: bundle)
            try await AuthServiceClient.shared.storeRecoveryBundle(ciphertext: Data(ciphertext))
            vaultKey = []  // clear from memory after successful upload
            isConfigured = true
            setupStep = .done
        } catch {
            setupStep = .failed(error.localizedDescription)
        }
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

    func reconstructAndRestore(username: String) async {
        recoveryStep = .reconstructing
        do {
            let reconstructedKey = try srReconstructVaultKey(mnemonics: enteredShares)
            guard let ciphertext = try await AuthServiceClient.shared.getRecoveryBundle(username: username) else {
                recoveryStep = .failed("no recovery bundle found for this identity")
                return
            }
            let bundle = try srOpenRecoveryBundle(vaultKey: reconstructedKey, ciphertext: [UInt8](ciphertext))
            let km = KeychainManager.shared
            km.saveDeviceSigningKey(bundle.deviceSigningKey)
            km.saveDeviceIdentityKey(bundle.deviceIdentityKey)
            // deviceId is restored implicitly via key re-registration flow
            recoveryStep = .done
        } catch {
            recoveryStep = .failed(error.localizedDescription)
        }
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
        vaultKey = []
    }
}
