//
//  VeilVoucherAvailability.swift
//  Construct Messenger
//
//  Whether to offer the "give someone access" action at all.
//
//  `IssueBootstrapVoucher` is feature-flagged on the server (`VEIL_BOOTSTRAP_VOUCHER`)
//  and answers `UNIMPLEMENTED` while the flag is off. There is no capability-discovery
//  RPC, so availability is learned the only way it can be — by asking once and
//  remembering the answer.
//
//  Remembered with an expiry rather than permanently: the flag is an operator switch
//  that can be turned on at any time, and a client that latched "unavailable" for the
//  life of the install would need an app update to notice. A day is short enough that
//  enabling the flag surfaces the action on its own, and long enough that a disabled
//  deployment is asked roughly once per day per device.
//

import Foundation

enum VeilVoucherAvailability {

    /// How long an `UNIMPLEMENTED` answer suppresses the action.
    static let suppressionWindow: TimeInterval = 24 * 3600

    private static let defaultsKey = "veil.voucher.unavailable_until"

    // MARK: - Pure decision (unit-tested)

    /// Whether the action should be offered, given the remembered answer.
    ///
    /// Unknown (never asked) counts as available: the cost of asking once is one unary
    /// RPC that fails fast, and the cost of assuming unavailable is an action that never
    /// appears on a deployment where it works.
    static func isOffered(unavailableUntil: Date?, now: Date) -> Bool {
        guard let unavailableUntil else { return true }
        return now >= unavailableUntil
    }

    // MARK: - Stored answer

    static var isOffered: Bool {
        isOffered(unavailableUntil: unavailableUntil, now: Date())
    }

    static var unavailableUntil: Date? {
        let raw = UserDefaults.standard.double(forKey: defaultsKey)
        return raw > 0 ? Date(timeIntervalSince1970: raw) : nil
    }

    /// Record that the server answered `UNIMPLEMENTED`.
    static func markUnavailable(now: Date = Date()) {
        UserDefaults.standard.set(
            now.addingTimeInterval(suppressionWindow).timeIntervalSince1970,
            forKey: defaultsKey
        )
        Log.info("VEIL voucher: server reports the flow is disabled — hiding the action for 24h", category: "VEIL")
    }

    /// Record that the server answered — the flow exists.
    static func markAvailable() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}
