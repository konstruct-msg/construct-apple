//
//  AccountRecoveryViewModel.swift
//  ConstructMessenger
//
//  Manages all three account recovery flows:
//    1. Setup  — generate mnemonic, quiz confirmation, call SetRecoveryKey
//    2. Status — check if recovery is set up (banner / fingerprint display)
//    3. Recover — enter mnemonic on new device, call RecoverAccount
//    4. Confirm — enter mnemonic on a device that does not know the account's address
//
//  Every flow that has the phrase in hand leaves this device knowing the account's address
//  (`AccountAddress.rememberOwn`): the address is the recovery public key, and the phrase is the
//  only source of it this app trusts.
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
    private var statusLoadTask: Task<Void, Never>? = nil

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

    // MARK: - Confirm flow state

    enum ConfirmStep: Equatable {
        case idle
        case checking
        case done
        case failed(String)
    }

    var confirmStep: ConfirmStep = .idle
    /// The phrase as typed or pasted: twelve words, any whitespace between them.
    var confirmPhrase: String = ""

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
        guard !mnemonic.isEmpty, !quizIndices.isEmpty else { return false }
        return quizIndices.allSatisfy { idx in
            guard idx < mnemonic.count else { return false }
            return quizAnswers[idx]?.trimmingCharacters(in: .whitespaces).lowercased()
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
                publicKey: keypair.publicKey,
                signature: Data(sigBytes),
                timestamp: timestamp
            )

            isSetup = true
            fingerprint = result.fingerprint
            AccountAddress.rememberOwn(keypair.publicKey)
            UserDefaults.standard.set(true, forKey: Self.udKeyIsSetup)
            setupStep = .done(fingerprint: result.fingerprint)
            mnemonic = []   // clear sensitive data after switching away from display view
        } catch {
            setupStep = .failed(errorMessage(from: error))
        }
    }

    func resetSetup() {
        setupStep = .idle
        mnemonic = []
        quizIndices = []
        quizAnswers = [:]
    }

    // MARK: - Status check

    func loadStatus() async {
        guard !statusLoaded else { return }
        if let inFlight = statusLoadTask {
            await inFlight.value
            return
        }

        let task = Task { @MainActor in
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
        statusLoadTask = task
        await task.value
        statusLoadTask = nil
    }

    /// Force-refresh (e.g. after returning from setup sheet)
    func refreshStatus() async {
        statusLoaded = false
        await loadStatus()
    }

    /// Call on logout to clear cached state
    func clearLocalCache() {
        statusLoadTask?.cancel()
        statusLoadTask = nil
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

            // 4. Call RecoverAccount (no auth header).
            // Normalize the identifier to match registration (server hashes
            // `username.trim().to_lowercase()`); a UUID is unaffected by lowercasing.
            // Defense-in-depth: the server now normalizes too, but this makes recovery work
            // against an older server and mirrors what the user actually registered.
            let identifier = recoverIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let response = try await AuthServiceClient.shared.recoverAccount(
                identifier: identifier,
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
            AuthSessionManager.shared.saveTokens(
                accessToken: response.accessToken,
                refreshToken: response.refreshToken,
                expiresIn: Int(response.expiresAt ?? 0),
                userId: response.userId
            )
            VeilProxyManager.shared.configureFromServer(cert: response.veilBridgeCert ?? "")
            // The server just accepted a signature by this key as the account's, so it is the
            // account's recovery key — and therefore its address.
            AccountAddress.rememberOwn(keypair.publicKey)

            Task {
                _ = try? await OtpkReplenishmentService.generateAndUpload(
                    count: 100,
                    deviceId: deviceId,
                    replaceExisting: true
                )
            }

            // Force-rotate SPK after recovery: the server still holds the original
            // device's SPK (which may be stale). Upload a fresh SPK so peers can
            // init sessions without hitting the Rust 14-day staleness rejection.
            Task { [weak self] in
                _ = self
                try? await PreKeyRotationService.shared.forceRotate(
                    deviceId: deviceId,
                    reason: .reinstall
                )
            }
            recoverStep = .done
            enteredWords = Array(repeating: "", count: 12)  // clear sensitive data after step change
        } catch {
            recoverStep = .failed(errorMessage(from: error))
        }
    }

    // MARK: - Confirm Flow

    /// Teach this device the account's address from the phrase.
    ///
    /// The key is derived here and compared with the fingerprint the server reports for the
    /// account. The phrase never leaves the device, and the server can only make the comparison
    /// fail — it cannot make this device adopt a key the phrase did not produce.
    func submitConfirm() async {
        let phrase = confirmPhrase
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.lowercased() }
            .joined(separator: " ")
        guard validateMnemonic(mnemonic: phrase) else {
            confirmStep = .failed(NSLocalizedString("recovery_confirm_invalid_phrase", comment: ""))
            return
        }
        confirmStep = .checking
        do {
            let keypair = try deriveRecoveryKeypair(seed: try mnemonicToSeed(mnemonic: phrase))
            let status = try await AuthServiceClient.shared.getRecoveryStatus()
            guard status.isSetup, let fingerprint = status.fingerprint else {
                confirmStep = .failed(NSLocalizedString("recovery_error_not_configured", comment: ""))
                return
            }
            let key = keypair.publicKey
            guard AccountAddress.matchesServerFingerprint(key, fingerprint: fingerprint) else {
                confirmStep = .failed(NSLocalizedString("recovery_confirm_other_account", comment: ""))
                return
            }
            AccountAddress.rememberOwn(key)
            confirmPhrase = ""
            confirmStep = .done
        } catch {
            confirmStep = .failed(errorMessage(from: error))
        }
    }

    func resetConfirm() {
        confirmStep = .idle
        confirmPhrase = ""
    }

    func resetRecover() {
        recoverStep = .idle
        enteredWords = Array(repeating: "", count: 12)
        recoverIdentifier = ""
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
