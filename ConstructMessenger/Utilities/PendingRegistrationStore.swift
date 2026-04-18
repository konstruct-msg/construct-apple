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

import Foundation

enum PendingRegistrationStore {
    private static let key = "construct.pendingRegistrationBundle"

    static func hasPendingBundle() -> Bool {
        UserDefaults.standard.dictionary(forKey: key) != nil
    }

    static func save(
        identityPublic: String,
        signedPrekeyPublic: String,
        signature: String,
        verifyingKey: String,
        suiteId: String
    ) {
        let dict: [String: String] = [
            "identityPublic": identityPublic,
            "signedPrekeyPublic": signedPrekeyPublic,
            "signature": signature,
            "verifyingKey": verifyingKey,
            "suiteId": suiteId
        ]
        UserDefaults.standard.set(dict, forKey: key)
    }

    static func load() -> (identityPublic: String, signedPrekeyPublic: String, signature: String, verifyingKey: String, suiteId: String)? {
        guard let dict = UserDefaults.standard.dictionary(forKey: key) as? [String: String],
              let ip = dict["identityPublic"],
              let spk = dict["signedPrekeyPublic"],
              let sig = dict["signature"],
              let vk = dict["verifyingKey"],
              let sid = dict["suiteId"] else { return nil }
        return (ip, spk, sig, vk, sid)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
