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
//  The key is hybrid Ed25519 + ML-DSA-65 (`RecoveryKey`). An account set up before that has the
//  Ed25519 key alone, and every flow that has the phrase in hand completes it (`upgrade`); one
//  whose phrase is nowhere on the device asks for it once (`upgradeNeeded`, the gate's `.upgrade`).
//

import Foundation
import GRPCCore
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
    var quizAnswers: [Int: String] = [:]  // index → the word the user picked
    /// Index → the words offered for it: the right one and others from the same phrase. Picking
    /// is the check (owner's decision 2026-10-04); typing on a phone was the wall.
    var quizOptions: [Int: [String]] = [:]

    /// What the setup screen is doing: making a key and setting it (no passcode on this device,
    /// or no key yet), showing one that was made silently so the person can copy it, or one of
    /// the answers for an account that has its key already.
    enum SetupMode: Equatable {
        case create
        case backupHeld
        /// The server holds the account's key and the phrase is not on this device. The key cannot
        /// be replaced, so a new phrase would only be refused after the person had copied it.
        case alreadySet
        /// The account has its key and this device does not know the address it gives: the
        /// person enters the phrase once (`submitConfirm`), as the invite gate asks.
        case confirm
        /// Nobody has said whether the account has a key — the status did not load and none was
        /// cached. Offering a new phrase here is the guess the server refuses.
        case unavailable
    }
    var setupMode: SetupMode = .create

    /// The whole rule for which flow the setup screen opens on. A held phrase wins: it is the
    /// account's key, waiting to be copied. Without one, a key the server has reported decides:
    /// a device that knows its address, or whose phrase is lost and cannot be entered, is told
    /// so; any other enters the phrase. A new phrase is offered only once the server has said
    /// there is no key.
    static func setupMode(
        held: Bool,
        isSetup: Bool,
        answered: Bool,
        knowsAddress: Bool,
        phraseLost: Bool
    ) -> SetupMode {
        if held { return .backupHeld }
        if isSetup { return knowsAddress || phraseLost ? .alreadySet : .confirm }
        return answered ? .create : .unavailable
    }

    /// The silent key's phrase waits in the vault until it is copied
    /// (`decisions/recovery-key-backup-is-deferred-not-skipped.md`).
    private(set) var backupPending = false
    private let phraseStore: any RecoveryPhraseStore & Sendable = RecoveryPhraseVault.shared
    private let marks = RecoveryBackupMarks()

    /// What the chat list should say about the copy (`RecoveryReminder.decide`). Recomputed with
    /// the status, not per render — it asks the Keychain.
    private(set) var reminder: RecoveryReminder = .none
    /// The silent key's phrase left the device before it was copied — whatever the reminder's
    /// snooze says. Settings show it permanently; it cannot be fixed, only known.
    private(set) var phraseLost = false

    /// The person closed the reminder: ask again after the same delay.
    func snoozeReminder() {
        marks.snooze()
        refreshBackupPending()
    }

    /// Settings asks for a copy while there is no key or the silent one is not copied yet.
    var needsBackup: Bool { statusLoaded && (!isSetup || backupPending) }

    /// The account's key is Ed25519 alone and no phrase on this device can complete it: the
    /// person enters it once. A held phrase completes it when it is copied instead.
    var upgradeNeeded: Bool { statusLoaded && isSetup && !isHybrid && !backupPending }

    // MARK: - Recovery status state

    var isSetup: Bool = false
    /// The account's key has its ML-DSA-65 half. Taken as true until the server says otherwise,
    /// so nothing asks for the phrase on a status that never loaded.
    var isHybrid: Bool = true
    var fingerprint: String? = nil
    var lastUsedAt: Int64? = nil
    var statusLoaded: Bool = false
    /// The server answered the last status request. `statusLoaded` turns true on a failure too
    /// (the banner should stop waiting); this is what says `isSetup == false` means "no key".
    private(set) var statusAnswered = false
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

    /// Which flow the screen opens on. Called when it appears.
    func prepareSetup() {
        refreshBackupPending()
        setupMode = Self.setupMode(
            held: backupPending,
            isSetup: isSetup,
            answered: statusAnswered,
            knowsAddress: AccountAddress.own() != nil,
            phraseLost: phraseLost
        )
    }

    func refreshBackupPending() {
        guard let userId = AuthSessionManager.shared.currentUserId else {
            backupPending = false
            reminder = .none
            phraseLost = false
            return
        }
        backupPending = phraseStore.hasHeld(account: userId)
        phraseLost = RecoveryReminder.decide(
            now: Date(),
            silentAt: marks.silentAt(account: userId),
            copied: marks.copied,
            phrase: phraseStore.phrasePresence(account: userId),
            snoozedUntil: nil
        ) == .phraseLost
        reminder = RecoveryReminder.decide(
            now: Date(),
            silentAt: marks.silentAt(account: userId),
            copied: marks.copied,
            phrase: phraseStore.phrasePresence(account: userId),
            snoozedUntil: marks.snoozedUntil
        )
    }

    /// Shows the silently made phrase, after Face ID / Touch ID / the passcode.
    func startBackup() async {
        guard let userId = AuthSessionManager.shared.currentUserId,
              let phrase = await phraseStore.readHeld(
                account: userId,
                reason: NSLocalizedString("recovery_backup_auth_reason", comment: "")
              )
        else { return }
        beginQuiz(with: phrase)
    }

    func startSetup() {
        guard setupMode == .create else { return }
        do {
            beginQuiz(with: try generateMnemonic(wordCount: 12))
        } catch {
            Log.error("Recovery setup: phrase generation failed: \(error)", category: "Recovery")
            setupStep = .failed(error.userFacingMessage)
        }
    }

    private func beginQuiz(with phrase: String) {
        mnemonic = phrase.split(separator: " ").map(String.init)
        quizIndices = threeRandomIndices(count: mnemonic.count)
        quizAnswers = [:]
        var generator = SystemRandomNumberGenerator()
        quizOptions = Dictionary(uniqueKeysWithValues: quizIndices.map {
            ($0, Self.quizOptions(for: mnemonic, index: $0, using: &generator))
        })
        setupStep = .displayWords
    }

    /// The word at `index` and up to three others from the same phrase, shuffled. Decoys from the
    /// phrase itself are the point: they are all words the person just saw, so the pick checks the
    /// position they wrote down, not whether a word looks familiar.
    static func quizOptions<R: RandomNumberGenerator>(
        for mnemonic: [String],
        index: Int,
        count: Int = 4,
        using generator: inout R
    ) -> [String] {
        guard mnemonic.indices.contains(index) else { return [] }
        let answer = mnemonic[index]
        var decoys: [String] = []
        for word in mnemonic.shuffled(using: &generator)
        where word != answer && !decoys.contains(word) && decoys.count < count - 1 {
            decoys.append(word)
        }
        return ([answer] + decoys).shuffled(using: &generator)
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
        if setupMode == .backupHeld {
            // The key is on the server already; copying it is all that was left. The phrase
            // leaves the device now, and the rule "never stored" applies again — so a key still
            // Ed25519 alone is completed first, while the phrase is in hand. A failure does not
            // hold the copy back: `upgradeNeeded` asks for the phrase later.
            if isSetup && !isHybrid {
                do {
                    try await upgrade(phrase: mnemonic.joined(separator: " "), userId: userId)
                } catch {
                    logFailure("upgrade", error)
                }
            }
            phraseStore.forgetHeld()
            marks.markCopied()
            refreshBackupPending()
            setupStep = .done(fingerprint: fingerprint ?? "")
            mnemonic = []
            return
        }
        guard setupMode == .create else { return }
        setupStep = .uploading
        do {
            let signed = try RecoveryKey.setup(
                phrase: mnemonic.joined(separator: " "),
                accountId: userId
            )
            let result = try await AuthServiceClient.shared.setRecoveryKey(signed)

            isSetup = true
            isHybrid = true
            fingerprint = result.fingerprint
            AccountAddress.rememberOwn(signed.address)
            UserDefaults.standard.set(true, forKey: Self.udKeyIsSetup)
            setupStep = .done(fingerprint: result.fingerprint)
            mnemonic = []   // clear sensitive data after switching away from display view
        } catch {
            logFailure("setup", error)
            setupStep = .failed(Self.errorMessage(from: error))
        }
    }

    func resetSetup() {
        setupStep = .idle
        mnemonic = []
        quizIndices = []
        quizAnswers = [:]
        quizOptions = [:]
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
                isHybrid = status.isHybrid
                fingerprint = status.fingerprint
                lastUsedAt = status.lastUsedAt
                statusAnswered = true
                if status.isSetup {
                    UserDefaults.standard.set(true, forKey: Self.udKeyIsSetup)
                }
                refreshBackupPending()
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
        isHybrid = true
        fingerprint = nil
        lastUsedAt = nil
        statusLoaded = false
        statusAnswered = false
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
            // 1. Generate fresh device keys
            let (deviceId, bundle) = try CryptoManager.shared.generateRegistrationBundle()

            // 2. The phrase's key hands the account to exactly these keys: the claim names them,
            // so a request seen on the way cannot be replayed with others.
            let claim = try RecoveryKey.claim(
                phrase: enteredMnemonic,
                deviceId: deviceId,
                verifyingKey: bundle.verifyingKey,
                identityPublic: bundle.identityPublic
            )

            var publicKeys = Shared_Proto_Services_V1_DevicePublicKeys()
            publicKeys.verifyingKey = bundle.verifyingKey
            publicKeys.identityPublic = bundle.identityPublic
            publicKeys.signedPrekeyPublic = bundle.signedPrekeyPublic
            publicKeys.signedPrekeySignature = bundle.signature
            publicKeys.cryptoSuite = "Curve25519+Ed25519"

            // 3. Call RecoverAccount (no auth header).
            // Normalize the identifier to match registration (server hashes
            // `username.trim().to_lowercase()`); a UUID is unaffected by lowercasing.
            // Defense-in-depth: the server now normalizes too, but this makes recovery work
            // against an older server and mirrors what the user actually registered.
            let identifier = recoverIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let response = try await AuthServiceClient.shared.recoverAccount(
                identifier: identifier,
                claim: claim,
                deviceId: deviceId,
                deviceName: DeviceInfo.deviceName,
                publicKeys: publicKeys
            )

            // 4. Persist the device id and tokens (the keys are in the record the bundle saved)
            KeychainManager.shared.saveDeviceID(deviceId)
            AuthSessionManager.shared.saveTokens(
                accessToken: response.accessToken,
                refreshToken: response.refreshToken,
                expiresIn: Int(response.expiresAt ?? 0),
                userId: response.userId
            )
            VeilProxyManager.shared.configureFromServer(cert: response.veilBridgeCert ?? "")
            // The server just accepted a signature by this key as the account's, so it is the
            // account's recovery key — and therefore its address. A recovered Ed25519 account is
            // hybrid now: the server kept the claim's ML-DSA half.
            AccountAddress.rememberOwn(claim.address)

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
            logFailure("recover", error)
            recoverStep = .failed(Self.errorMessage(from: error))
        }
    }

    // MARK: - Confirm Flow

    /// Teach this device the account's address from the phrase.
    ///
    /// The key is derived here and compared with the fingerprint the server reports for the
    /// account. The phrase never leaves the device, and the server can only make the comparison
    /// fail — it cannot make this device adopt a key the phrase did not produce.
    ///
    /// An account whose key is Ed25519 alone is completed with the same input (`upgrade`): this
    /// is the one place a phrase that is nowhere on the device can do it.
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
            let key = try RecoveryKey.address(phrase: phrase)
            let status = try await AuthServiceClient.shared.getRecoveryStatus()
            guard status.isSetup, let fingerprint = status.fingerprint else {
                confirmStep = .failed(NSLocalizedString("recovery_error_not_configured", comment: ""))
                return
            }
            guard AccountAddress.matchesServerFingerprint(key, fingerprint: fingerprint) else {
                confirmStep = .failed(NSLocalizedString("recovery_confirm_other_account", comment: ""))
                return
            }
            AccountAddress.rememberOwn(key)
            isHybrid = status.isHybrid
            if !status.isHybrid, let userId = AuthSessionManager.shared.currentUserId {
                try await upgrade(phrase: phrase, userId: userId)
            }
            confirmPhrase = ""
            confirmStep = .done
        } catch {
            logFailure("confirm", error)
            confirmStep = .failed(Self.errorMessage(from: error))
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

    // MARK: - Upgrade

    /// Completes the account's Ed25519 key with the phrase's ML-DSA-65 half. The server takes it
    /// only when the key's Ed25519 half is the one it holds, signed by both halves.
    private func upgrade(phrase: String, userId: String) async throws {
        let signed = try RecoveryKey.setup(phrase: phrase, accountId: userId)
        _ = try await AuthServiceClient.shared.setRecoveryKey(signed)
        isHybrid = true
        Log.info("Recovery key: completed to hybrid", category: "Recovery")
    }

    // MARK: - Helpers

    private func threeRandomIndices(count: Int) -> [Int] {
        Array((0..<count).shuffled().prefix(3)).sorted()
    }

    /// What the user reads when a recovery RPC fails, decided by the status code.
    ///
    /// Until 2026-09-30 this searched `localizedDescription` for "ALREADY_EXISTS" and the like. A
    /// grpc-swift 2 `RPCError` describes itself as "The operation couldn't be completed
    /// (GRPCCore.RPCError error 1)", so no branch ever matched: every refusal — a key already set,
    /// an expired signature, a server fault — showed that sentence, and nothing was logged.
    static func errorMessage(from error: Error) -> String {
        guard let rpc = error as? RPCError else { return error.userFacingMessage }
        switch rpc.code {
        case .notFound: return NSLocalizedString("recovery_error_not_found", comment: "")
        case .failedPrecondition: return NSLocalizedString("recovery_error_not_configured", comment: "")
        case .permissionDenied: return NSLocalizedString("recovery_error_wrong_phrase", comment: "")
        case .resourceExhausted: return NSLocalizedString("recovery_error_cooldown", comment: "")
        case .alreadyExists: return NSLocalizedString("recovery_error_already_set", comment: "")
        default: return error.userFacingMessage
        }
    }

    /// The code and the server's own words, never the phrase or a key.
    private func logFailure(_ flow: String, _ error: Error) {
        if let rpc = error as? RPCError {
            Log.error("Recovery \(flow) refused: \(rpc.code) — \(rpc.message)", category: "Recovery")
        } else {
            Log.error("Recovery \(flow) failed: \(error.localizedDescription)", category: "Recovery")
        }
    }

    enum RecoveryError: LocalizedError {
        case bundleGenerationFailed
        var errorDescription: String? { "Failed to generate new device keys" }
    }
}
