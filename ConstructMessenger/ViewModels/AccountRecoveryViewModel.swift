//
//  AccountRecoveryViewModel.swift
//  ConstructMessenger
//
//  Manages all three account recovery flows:
//    1. Setup  — generate mnemonic, quiz confirmation, call SetRecoveryKey
//    2. Status — check if recovery is set up (banner / fingerprint display)
//    3. Recover — enter mnemonic on new device, call RecoverAccount
//

import Foundation
import Observation

@MainActor
@Observable
final class AccountRecoveryViewModel {

    // MARK: - Setup flow state

    enum SetupStep {
        case idle
        case displayWords
        case quiz
        case uploading
        case done(fingerprint: String)
        case failed(String)
    }

    var setupStep: SetupStep = .idle
    var mnemonic: [String] = []           // 12 words shown to user
    var quizIndices: [Int] = []           // 3 random indices for word quiz
    var quizAnswers: [Int: String] = [:]  // index → user input

    // MARK: - Recovery status state

    var isSetup: Bool = false
    var fingerprint: String? = nil
    var lastUsedAt: Int64? = nil
    var statusLoaded: Bool = false

    private static let udKeyIsSetup = "recovery_is_setup"

    // MARK: - Recover flow state

    enum RecoverStep {
        case idle
        case enterPhrase
        case recovering
        case done
        case failed(String)
    }

    var recoverStep: RecoverStep = .idle
    var enteredWords: [String] = Array(repeating: "", count: 12)
    var recoverIdentifier: String = ""    // username or UUID to identify account

    // MARK: - Setup Flow

    func startSetup() {
        do {
            let phrase = try generateMnemonic(wordCount: 12)
            mnemonic = phrase.split(separator: " ").map(String.init)
            quizIndices = threeRandomIndices(count: mnemonic.count)
            quizAnswers = [:]
            setupStep = .displayWords
        } catch {
            setupStep = .failed(error.userFacingMessage)
        }
    }

    func proceedToQuiz() {
        setupStep = .quiz
    }

    var quizPassed: Bool {
        quizIndices.allSatisfy { idx in
            quizAnswers[idx]?.trimmingCharacters(in: .whitespaces).lowercased()
                == mnemonic[idx].lowercased()
        }
    }

    func submitSetup(userId: String) async {
        guard quizPassed else {
            setupStep = .failed(NSLocalizedString("recovery_quiz_failed", comment: ""))
            return
        }
        setupStep = .uploading
        do {
            let seed = try mnemonicToSeed(mnemonic: mnemonic.joined(separator: " "))
            let keypair = try deriveRecoveryKeypair(seed: seed)

            let timestamp = Int64(Date().timeIntervalSince1970)
            let message = "CONSTRUCT_RECOVERY_SETUP:\(userId):\(timestamp)"
            let sigBytes = try signRecoveryChallenge(
                privateKey: keypair.privateKey,
                message: message
            )

            let result = try await AuthServiceClient.shared.setRecoveryKey(
                publicKey: Data(keypair.publicKey),
                signature: Data(sigBytes),
                timestamp: timestamp
            )

            isSetup = true
            fingerprint = result.fingerprint
            UserDefaults.standard.set(true, forKey: Self.udKeyIsSetup)
            mnemonic = []   // clear sensitive data
            setupStep = .done(fingerprint: result.fingerprint)
        } catch {
            setupStep = .failed(errorMessage(from: error))
        }
    }

    func resetSetup() {
        mnemonic = []
        quizIndices = []
        quizAnswers = [:]
        setupStep = .idle
    }

    // MARK: - Status check

    func loadStatus() async {
        guard !statusLoaded else { return }
        // Apply cached value immediately so the banner doesn't flash on app update
        if UserDefaults.standard.bool(forKey: Self.udKeyIsSetup) {
            isSetup = true
        }
        do {
            let status = try await AuthServiceClient.shared.getRecoveryStatus()
            isSetup = status.isSetup
            fingerprint = status.fingerprint
            lastUsedAt = status.lastUsedAt
            if status.isSetup {
                UserDefaults.standard.set(true, forKey: Self.udKeyIsSetup)
            }
            statusLoaded = true
        } catch {
            // Non-fatal — silently skip banner on network error
            statusLoaded = true
        }
    }

    /// Force-refresh (e.g. after returning from setup sheet)
    func refreshStatus() async {
        statusLoaded = false
        await loadStatus()
    }

    /// Call on logout to clear cached state
    func clearLocalCache() {
        UserDefaults.standard.removeObject(forKey: Self.udKeyIsSetup)
        UserDefaults.standard.removeObject(forKey: "recovery_banner_dismissed")
        isSetup = false
        fingerprint = nil
        lastUsedAt = nil
        statusLoaded = false
    }

    // MARK: - Recover Flow

    func startRecover() {
        enteredWords = Array(repeating: "", count: 12)
        recoverIdentifier = ""
        recoverStep = .enterPhrase
    }

    var enteredMnemonic: String {
        enteredWords.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.joined(separator: " ")
    }

    var enteredMnemonicValid: Bool {
        validateMnemonic(mnemonic: enteredMnemonic)
    }

    func submitRecover() async {
        guard enteredMnemonicValid, !recoverIdentifier.isEmpty else { return }
        recoverStep = .recovering
        do {
            // 1. Derive keypair from entered phrase
            let seed = try mnemonicToSeed(mnemonic: enteredMnemonic)
            let keypair = try deriveRecoveryKeypair(seed: seed)

            // 2. Client-generated challenge (timestamp string)
            let challenge = String(Int64(Date().timeIntervalSince1970))
            let sigBytes = try signRecoveryChallenge(
                privateKey: keypair.privateKey,
                message: challenge
            )

            // 3. Generate fresh device keys
            let (deviceId, bundle, signingKeyData, identityKeyData) =
                try CryptoManager.shared.generateRegistrationBundle()

            var publicKeys = Shared_Proto_Services_V1_DevicePublicKeys()
            publicKeys.verifyingKey = bundle.verifyingKey
            publicKeys.identityPublic = bundle.identityPublic
            publicKeys.signedPrekeyPublic = bundle.signedPrekeyPublic
            publicKeys.signedPrekeySignature = bundle.signature
            publicKeys.cryptoSuite = "Curve25519+Ed25519"

            // 4. Call RecoverAccount (no auth header)
            let response = try await AuthServiceClient.shared.recoverAccount(
                identifier: recoverIdentifier,
                challenge: challenge,
                recoverySignature: Data(sigBytes),
                deviceId: deviceId,
                deviceName: DeviceInfo.deviceName,
                publicKeys: publicKeys
            )

            // 5. Persist new keys and tokens
            KeychainManager.shared.saveDeviceID(deviceId)
            KeychainManager.shared.saveDeviceSigningKey(signingKeyData)
            KeychainManager.shared.saveDeviceIdentityKey(identityKeyData)
            SessionManager.shared.saveTokens(
                accessToken: response.accessToken,
                refreshToken: response.refreshToken,
                expiresIn: Int(response.expiresAt ?? 0),
                userId: response.userId
            )
            IceProxyManager.shared.configureFromServer(cert: response.iceBridgeCert ?? "")

            // 6. Upload new OTPKs (force replace)
            Task {
                try? await OtpkReplenishmentService.generateAndUpload(
                    count: 100,
                    deviceId: deviceId,
                    replaceExisting: true
                )
            }

            enteredWords = Array(repeating: "", count: 12)  // clear sensitive data
            recoverStep = .done
        } catch {
            recoverStep = .failed(errorMessage(from: error))
        }
    }

    func resetRecover() {
        enteredWords = Array(repeating: "", count: 12)
        recoverIdentifier = ""
        recoverStep = .idle
    }

    // MARK: - Helpers

    private func threeRandomIndices(count: Int) -> [Int] {
        Array((0..<count).shuffled().prefix(3)).sorted()
    }

    private func errorMessage(from error: Error) -> String {
        // Map gRPC status codes to user-friendly messages
        let desc = error.localizedDescription
        if desc.contains("NOT_FOUND") || desc.contains("not_found") {
            return NSLocalizedString("recovery_error_not_found", comment: "")
        } else if desc.contains("FAILED_PRECONDITION") {
            return NSLocalizedString("recovery_error_not_configured", comment: "")
        } else if desc.contains("PERMISSION_DENIED") {
            return NSLocalizedString("recovery_error_wrong_phrase", comment: "")
        } else if desc.contains("RESOURCE_EXHAUSTED") {
            return NSLocalizedString("recovery_error_cooldown", comment: "")
        } else if desc.contains("ALREADY_EXISTS") {
            return NSLocalizedString("recovery_error_already_set", comment: "")
        }
        return desc
    }

    enum RecoveryError: LocalizedError {
        case bundleGenerationFailed
        var errorDescription: String? { "Failed to generate new device keys" }
    }
}
