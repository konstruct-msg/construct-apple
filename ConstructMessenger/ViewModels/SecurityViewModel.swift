//
//  SecurityViewModel.swift
//  Construct Messenger
//
//  Created by Codex on 06.02.2026.
//

import Foundation
import LocalAuthentication
import CryptoKit
import Security
import Observation

@Observable
final class SecurityViewModel {
    private(set) var isPinEnabled: Bool
    var isUnlocked: Bool
    var isBiometricAvailable: Bool = false
    private(set) var biometricType: LABiometryType = .none
    var isBiometricEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isBiometricEnabled, forKey: Self.biometricEnabledKey)
        }
    }

    private static let pinHashKey = "app_pin_hash"
    private static let pinSaltKey = "app_pin_salt"
    private static let pinLengthKey = "app_pin_length"
    private static let biometricEnabledKey = "security.useBiometrics"

    init() {
        let hasPin = SecurityViewModel.hasSavedPin()
        self.isPinEnabled = hasPin
        self.isUnlocked = !hasPin
        self.isBiometricEnabled = UserDefaults.standard.bool(forKey: Self.biometricEnabledKey)
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
        if !hasPin {
            isUnlocked = true
            isBiometricEnabled = false
        }
    }

    func lockIfNeeded() {
        guard isPinEnabled else { return }
        isUnlocked = false
    }

    func setPin(_ pin: String) {
        let salt = randomSalt()
        let hash = hashPin(pin, salt: salt)
        _ = KeychainManager.shared.saveData(hash, forKey: Self.pinHashKey)
        _ = KeychainManager.shared.saveData(salt, forKey: Self.pinSaltKey)
        UserDefaults.standard.set(pin.count, forKey: Self.pinLengthKey)
        isPinEnabled = true
        isUnlocked = true
    }

    func disablePin() {
        KeychainManager.shared.deleteData(forKey: Self.pinHashKey)
        KeychainManager.shared.deleteData(forKey: Self.pinSaltKey)
        UserDefaults.standard.removeObject(forKey: Self.pinLengthKey)
        isPinEnabled = false
        isUnlocked = true
        isBiometricEnabled = false
    }

    func verifyPin(_ pin: String) -> Bool {
        guard let savedHash = KeychainManager.shared.loadData(forKey: Self.pinHashKey),
              let salt = KeychainManager.shared.loadData(forKey: Self.pinSaltKey) else {
            return false
        }
        let hash = hashPin(pin, salt: salt)
        return hash == savedHash
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

    private func hashPin(_ pin: String, salt: Data) -> Data {
        var data = Data()
        data.append(salt)
        data.append(pin.data(using: .utf8) ?? Data())
        let digest = SHA256.hash(data: data)
        return Data(digest)
    }

    private func randomSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    private static func hasSavedPin() -> Bool {
        let hash = KeychainManager.shared.loadData(forKey: pinHashKey)
        let salt = KeychainManager.shared.loadData(forKey: pinSaltKey)
        return hash != nil && salt != nil
    }
}
