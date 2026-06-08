//
//  SecurityViewModel.swift
//  Construct Messenger
//
//  Created by Codex on 06.02.2026.
//

import Foundation
import LocalAuthentication
import CryptoKit
import CommonCrypto
import Security
import Observation

/// How long the app waits in the background before requiring PIN on return.
enum LockDelay: Int, CaseIterable, Identifiable {
    case immediate = 0
    case thirtySeconds = 30
    case oneMinute = 60
    case fiveMinutes = 300
    case tenMinutes = 600

    var id: Int { rawValue }

    var localizedTitle: String {
        switch self {
        case .immediate:     return NSLocalizedString("lock_delay_immediate", comment: "")
        case .thirtySeconds: return NSLocalizedString("lock_delay_30s", comment: "")
        case .oneMinute:     return NSLocalizedString("lock_delay_1m", comment: "")
        case .fiveMinutes:   return NSLocalizedString("lock_delay_5m", comment: "")
        case .tenMinutes:    return NSLocalizedString("lock_delay_10m", comment: "")
        }
    }
}

@Observable
final class SecurityViewModel {
    private(set) var isPinEnabled: Bool
    private(set) var isDuresspinEnabled: Bool
    var isUnlocked: Bool
    var isBiometricAvailable: Bool = false
    private(set) var biometricType: LABiometryType = .none
    var isBiometricEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isBiometricEnabled, forKey: Self.biometricEnabledKey)
        }
    }
    var lockDelay: LockDelay {
        didSet {
            UserDefaults.standard.set(lockDelay.rawValue, forKey: Self.lockDelayKey)
        }
    }

    /// Timestamp of the most recent background/inactive transition; nil when in foreground.
    private var backgroundedAt: Date?

    private static let pinHashKey = "app_pin_hash"
    private static let pinSaltKey = "app_pin_salt"
    private static let pinLengthKey = "app_pin_length"
    private static let pinHashVersionKey = "app_pin_hash_version"
    private static let biometricEnabledKey = "security.useBiometrics"
    private static let lockDelayKey = "security.lockDelay"
    private static let duressPinHashKey = "app_duress_pin_hash"
    private static let duressPinSaltKey = "app_duress_pin_salt"
    private static let duressPinHashVersionKey = "app_duress_pin_hash_version"

    /// Hash version 1 = SHA-256(salt || pin) — legacy, migrated on first unlock
    /// Hash version 2 = PBKDF2-SHA256, 100k iterations, 32-byte salt
    private static let currentHashVersion = 2
    private static let pbkdf2Iterations: UInt32 = 100_000

    init() {
        let hasPin = SecurityViewModel.hasSavedPin()
        self.isPinEnabled = hasPin
        self.isDuresspinEnabled = SecurityViewModel.hasSavedDuressPin()
        self.isUnlocked = !hasPin
        self.isBiometricEnabled = UserDefaults.standard.bool(forKey: Self.biometricEnabledKey)
        let savedDelay = UserDefaults.standard.integer(forKey: Self.lockDelayKey)
        self.lockDelay = LockDelay(rawValue: savedDelay) ?? .immediate
        refreshBiometricAvailability()
        if !hasPin {
            self.isBiometricEnabled = false
        }
    }

    var requiresUnlock: Bool {
        isPinEnabled && !isUnlocked
    }

    var biometricDisplayName: String {
        switch biometricType {
        case .faceID:
            return NSLocalizedString("face_id", comment: "")
        case .touchID:
            return NSLocalizedString("touch_id", comment: "")
        default:
            return NSLocalizedString("biometric", comment: "Biometric")
        }
    }

    var biometricIconName: String {
        switch biometricType {
        case .touchID:
            return "touchid"
        default:
            return "faceid"
        }
    }

    func refreshPinState() {
        let hasPin = SecurityViewModel.hasSavedPin()
        isPinEnabled = hasPin
        isDuresspinEnabled = SecurityViewModel.hasSavedDuressPin()
        if !hasPin {
            isUnlocked = true
            isBiometricEnabled = false
        }
    }

    func lockIfNeeded() {
        guard isPinEnabled else { return }
        isUnlocked = false
    }

    /// Called when the app moves to background or inactive.
    /// Locks immediately if delay is .immediate; otherwise records the timestamp.
    func handleBackground() {
        guard isPinEnabled else { return }
        backgroundedAt = Date()
        if lockDelay == .immediate {
            isUnlocked = false
        }
    }

    /// Called when the app returns to the foreground.
    /// Locks if the elapsed background time exceeded the configured delay.
    func handleForeground() {
        guard isPinEnabled, isUnlocked else {
            backgroundedAt = nil
            return
        }
        defer { backgroundedAt = nil }
        guard let since = backgroundedAt, lockDelay != .immediate else { return }
        let elapsed = Date().timeIntervalSince(since)
        if elapsed >= TimeInterval(lockDelay.rawValue) {
            isUnlocked = false
        }
    }

    func setPin(_ pin: String) {
        let salt = randomSalt(bytes: 32)
        let hash = hashPinPBKDF2(pin, salt: salt)
        _ = KeychainManager.shared.saveData(hash, forKey: Self.pinHashKey)
        _ = KeychainManager.shared.saveData(salt, forKey: Self.pinSaltKey)
        _ = KeychainManager.shared.saveData(Data([UInt8(Self.currentHashVersion)]), forKey: Self.pinHashVersionKey)
        UserDefaults.standard.set(pin.count, forKey: Self.pinLengthKey)
        isPinEnabled = true
        isUnlocked = true
    }

    func disablePin() {
        KeychainManager.shared.deleteData(forKey: Self.pinHashKey)
        KeychainManager.shared.deleteData(forKey: Self.pinSaltKey)
        UserDefaults.standard.removeObject(forKey: Self.pinLengthKey)
        // Also remove duress PIN — can't have duress without main PIN
        disableDuressPin()
        isPinEnabled = false
        isUnlocked = true
        isBiometricEnabled = false
    }

    /// Destructive: removes ALL local PIN + duress + biometric state.
    ///
    /// SECURITY INVARIANT: a PIN must never be "reset in place" to regain entry to
    /// the same account — that would make the app-lock cosmetic (delete app → reset
    /// PIN → walk in). This method is therefore the local-half of an explicit,
    /// user-initiated *destructive* reset only: the caller (PinLockView escape hatch)
    /// pairs it with `AuthViewModel.wipeAndReregister()` so the device drops to fresh
    /// onboarding. The identity is recoverable afterwards only via seed phrase (if
    /// recovery was configured). It is NOT a silent path and is NOT triggered by any
    /// UserDefaults flag, so the `spkEpoch`/`pqxdh` anti-tamper invariants stand.
    func wipeSecurityState() {
        KeychainManager.shared.deleteData(forKey: Self.pinHashKey)
        KeychainManager.shared.deleteData(forKey: Self.pinSaltKey)
        KeychainManager.shared.deleteData(forKey: Self.pinHashVersionKey)
        KeychainManager.shared.deleteData(forKey: Self.duressPinHashKey)
        KeychainManager.shared.deleteData(forKey: Self.duressPinSaltKey)
        KeychainManager.shared.deleteData(forKey: Self.duressPinHashVersionKey)
        UserDefaults.standard.removeObject(forKey: Self.pinLengthKey)
        UserDefaults.standard.removeObject(forKey: Self.biometricEnabledKey)
        isPinEnabled = false
        isDuresspinEnabled = false
        isBiometricEnabled = false
        isUnlocked = true
    }

    // MARK: - Duress PIN

    /// Returns true and saves duress PIN if it doesn't match the main PIN.
    @discardableResult
    func setDuressPin(_ pin: String) -> Bool {
        guard !verifyPin(pin) else { return false } // must differ from main PIN
        let salt = randomSalt(bytes: 32)
        let hash = hashPinPBKDF2(pin, salt: salt)
        _ = KeychainManager.shared.saveData(hash, forKey: Self.duressPinHashKey)
        _ = KeychainManager.shared.saveData(salt, forKey: Self.duressPinSaltKey)
        _ = KeychainManager.shared.saveData(Data([UInt8(Self.currentHashVersion)]), forKey: Self.duressPinHashVersionKey)
        isDuresspinEnabled = true
        return true
    }

    func disableDuressPin() {
        KeychainManager.shared.deleteData(forKey: Self.duressPinHashKey)
        KeychainManager.shared.deleteData(forKey: Self.duressPinSaltKey)
        isDuresspinEnabled = false
    }

    func verifyDuressPin(_ pin: String) -> Bool {
        guard let savedHash = KeychainManager.shared.loadData(forKey: Self.duressPinHashKey),
              let salt = KeychainManager.shared.loadData(forKey: Self.duressPinSaltKey) else {
            return false
        }
        return verifyAndMigrateIfNeeded(
            pin: pin, savedHash: savedHash, salt: salt,
            versionKey: Self.duressPinHashVersionKey,
            hashKey: Self.duressPinHashKey,
            saltKey: Self.duressPinSaltKey
        )
    }

    func isDuressPinSameAsMain(_ pin: String) -> Bool {
        verifyPin(pin)
    }

    func verifyPin(_ pin: String) -> Bool {
        guard let savedHash = KeychainManager.shared.loadData(forKey: Self.pinHashKey),
              let salt = KeychainManager.shared.loadData(forKey: Self.pinSaltKey) else {
            return false
        }
        return verifyAndMigrateIfNeeded(
            pin: pin, savedHash: savedHash, salt: salt,
            versionKey: Self.pinHashVersionKey,
            hashKey: Self.pinHashKey,
            saltKey: Self.pinSaltKey
        )
    }

    /// Verifies PIN against saved hash. If hash is legacy (v1 SHA-256), transparently
    /// re-hashes with PBKDF2 on success so next unlock uses the stronger algorithm.
    private func verifyAndMigrateIfNeeded(
        pin: String,
        savedHash: Data,
        salt: Data,
        versionKey: String,
        hashKey: String,
        saltKey: String
    ) -> Bool {
        let versionData = KeychainManager.shared.loadData(forKey: versionKey)
        let version = versionData.flatMap { $0.first }.map(Int.init) ?? 1

        if version >= Self.currentHashVersion {
            let hash = hashPinPBKDF2(pin, salt: salt)
            return hash == savedHash
        }

        // Legacy v1: SHA-256(salt || pin)
        let legacyHash = hashPinLegacy(pin, salt: salt)
        guard legacyHash == savedHash else { return false }

        // Migrate: re-hash with PBKDF2 and overwrite stored hash
        let newSalt = randomSalt(bytes: 32)
        let newHash = hashPinPBKDF2(pin, salt: newSalt)
        _ = KeychainManager.shared.saveData(newHash, forKey: hashKey)
        _ = KeychainManager.shared.saveData(newSalt, forKey: saltKey)
        _ = KeychainManager.shared.saveData(Data([UInt8(Self.currentHashVersion)]), forKey: versionKey)
        return true
    }

    var pinLength: Int? {
        UserDefaults.standard.object(forKey: Self.pinLengthKey) as? Int
    }

    func refreshBiometricAvailability() {
        let context = LAContext()
        var error: NSError?
        let available = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        biometricType = context.biometryType
        isBiometricAvailable = available
        if !available {
            isBiometricEnabled = false
        }
    }

    func authenticateWithBiometrics(reason: String, completion: @escaping (Bool, String?) -> Void) {
        let context = LAContext()
        context.localizedCancelTitle = NSLocalizedString("cancel", comment: "")
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            DispatchQueue.main.async {
                completion(false, error?.localizedDescription)
            }
            return
        }

        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, evalError in
            DispatchQueue.main.async {
                completion(success, evalError?.localizedDescription)
            }
        }
    }

    private func hashPinPBKDF2(_ pin: String, salt: Data) -> Data {
        let pinData = pin.data(using: .utf8) ?? Data()
        var derivedKey = Data(repeating: 0, count: 32)
        derivedKey.withUnsafeMutableBytes { derivedPtr in
            salt.withUnsafeBytes { saltPtr in
                pinData.withUnsafeBytes { pinPtr in
                    _ = CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pinPtr.baseAddress?.assumingMemoryBound(to: Int8.self),
                        pinData.count,
                        saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        Self.pbkdf2Iterations,
                        derivedPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }
        return derivedKey
    }

    /// Legacy SHA-256 hash — only used for migrating existing stored PINs.
    private func hashPinLegacy(_ pin: String, salt: Data) -> Data {
        var data = Data()
        data.append(salt)
        data.append(pin.data(using: .utf8) ?? Data())
        let digest = SHA256.hash(data: data)
        return Data(digest)
    }

    private func randomSalt(bytes: Int = 32) -> Data {
        var buf = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &buf)
        return Data(buf)
    }

    private static func hasSavedPin() -> Bool {
        let hash = KeychainManager.shared.loadData(forKey: pinHashKey)
        let salt = KeychainManager.shared.loadData(forKey: pinSaltKey)
        return hash != nil && salt != nil
    }

    private static func hasSavedDuressPin() -> Bool {
        let hash = KeychainManager.shared.loadData(forKey: duressPinHashKey)
        let salt = KeychainManager.shared.loadData(forKey: duressPinSaltKey)
        return hash != nil && salt != nil
    }
}
