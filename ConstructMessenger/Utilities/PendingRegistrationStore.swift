//
//  PendingRegistrationStore.swift
//  Construct Messenger
//
//  Lightweight UserDefaults store for the registration bundle generated before the
//  `registerDevice` RPC. If the RPC times out, the bundle survives across launches so
//  the same identity can be retried without regenerating keys.
//
//  The bundle contains only PUBLIC keys — storing in UserDefaults is intentional.
//  Private keys are always in the Keychain (saved immediately after key generation).
//
//  Storage format: raw bytes are stored as `Data` in a `[String: Any]` dictionary
//  (UserDefaults serialises `Data` to its plist binary representation — no base64).
//

import Foundation

enum PendingRegistrationStore {
    private static let key = "construct.pendingRegistrationBundle"

    static func hasPendingBundle() -> Bool {
        UserDefaults.standard.dictionary(forKey: key) != nil
    }

    static func save(
        identityPublic: Data,
        signedPrekeyPublic: Data,
        signature: Data,
        verifyingKey: Data,
        suiteId: String
    ) {
        let dict: [String: Any] = [
            "identityPublic": identityPublic,
            "signedPrekeyPublic": signedPrekeyPublic,
            "signature": signature,
            "verifyingKey": verifyingKey,
            "suiteId": suiteId
        ]
        UserDefaults.standard.set(dict, forKey: key)
    }

    static func load() -> (identityPublic: Data, signedPrekeyPublic: Data, signature: Data, verifyingKey: Data, suiteId: String)? {
        guard let dict = UserDefaults.standard.dictionary(forKey: key),
              let ip = dict["identityPublic"] as? Data,
              let spk = dict["signedPrekeyPublic"] as? Data,
              let sig = dict["signature"] as? Data,
              let vk = dict["verifyingKey"] as? Data,
              let sid = dict["suiteId"] as? String else { return nil }
        return (ip, spk, sig, vk, sid)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
