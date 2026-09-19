//
//  DeviceLinkPendingPin.swift
//  Construct Messenger
//
//  Flow A QR `fp` stored with the pending link token, then bound to the
//  new account after ConfirmDeviceLink. Cleared when history finishes
//  or is skipped. Not a PAKE.
//

import Foundation

enum DeviceLinkPendingPin {
    private static let tokenPrefix = "ct.device_link.fp.token."
    private static let userPrefix = "ct.device_link.fp.user."

    static func store(_ fp: Data, forToken token: String) {
        guard fp.count == 32, !token.isEmpty else { return }
        UserDefaults.standard.set(fp, forKey: tokenPrefix + token)
    }

    static func load(forToken token: String) -> Data? {
        UserDefaults.standard.data(forKey: tokenPrefix + token)
    }

    static func bindToAccount(userId: String, fromToken token: String) {
        if let fp = load(forToken: token), !userId.isEmpty {
            UserDefaults.standard.set(fp, forKey: userPrefix + userId)
        }
        clear(forToken: token)
    }

    static func load(forUserId userId: String) -> Data? {
        UserDefaults.standard.data(forKey: userPrefix + userId)
    }

    static func clear(forToken token: String) {
        UserDefaults.standard.removeObject(forKey: tokenPrefix + token)
    }

    static func clear(forUserId userId: String) {
        UserDefaults.standard.removeObject(forKey: userPrefix + userId)
    }
}
