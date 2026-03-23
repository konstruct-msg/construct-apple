//
//  LocalRateLimiter.swift
//  Construct Messenger
//
//  Sliding-window rate limiter + warning counter.  All state in UserDefaults.
//

import Foundation

/// Per-device, per-sender rate limiter.
///
/// Limits are applied per *outgoing* message attempt (text, media, file).
/// Two tiers:
///  - **New account** (registration < 3 days): 30/hour, 100/day
///  - **Trusted account** (≥ 3 days): 200/hour, 1 000/day
///
/// Counters reset automatically when the time window expires.
final class LocalRateLimiter {

    static let shared = LocalRateLimiter()

    // MARK: - Tier configuration

    private let newAccountHourLimit  = 30
    private let newAccountDayLimit   = 100
    private let trustedHourLimit     = 200
    private let trustedDayLimit      = 1_000

    /// Age threshold for "trusted" account (3 days).
    private let trustedAccountAge: TimeInterval = 3 * 24 * 60 * 60

    // MARK: - UserDefaults keys

    private enum Key {
        static let hourCount    = "com.construct.antispam.hourCount"
        static let hourStart    = "com.construct.antispam.hourStart"
        static let dayCount     = "com.construct.antispam.dayCount"
        static let dayStart     = "com.construct.antispam.dayStart"
        static let warnings24h  = "com.construct.antispam.warnings24h"
        static let warnWindow   = "com.construct.antispam.warnWindow"
        static let regDate      = "com.construct.antispam.regDate"
        static let forceSend    = "com.construct.antispam.forceSendCount"
        static let forceBanEnd  = "com.construct.antispam.forceBanEnd"
    }

    private let defaults = UserDefaults.standard
    private init() {}

    // MARK: - Registration date

    /// Set once after the user registers so the limiter can detect the "new account" tier.
    func setRegistrationDate(_ date: Date) {
        if defaults.object(forKey: Key.regDate) == nil {
            defaults.set(date, forKey: Key.regDate)
        }
    }

    private var isTrustedAccount: Bool {
        guard let reg = defaults.object(forKey: Key.regDate) as? Date else { return false }
        return Date().timeIntervalSince(reg) >= trustedAccountAge
    }

    // MARK: - Rate check

    /// Result of a rate-limit check.
    enum RateCheckResult {
        case allowed
        /// User has sent too many messages this window.
        case rateLimited(resetIn: TimeInterval)
    }

    /// Check whether sending is allowed and record the attempt if so.
    ///
    /// - Returns: `.allowed` or `.rateLimited(resetIn:)`.
    func checkAndRecord() -> RateCheckResult {
        resetExpiredWindows()

        let hourLimit = isTrustedAccount ? trustedHourLimit  : newAccountHourLimit
        let dayLimit  = isTrustedAccount ? trustedDayLimit   : newAccountDayLimit

        let hourCount = defaults.integer(forKey: Key.hourCount)
        let dayCount  = defaults.integer(forKey: Key.dayCount)

        if hourCount >= hourLimit {
            let start = defaults.object(forKey: Key.hourStart) as? Date ?? Date()
            let resetIn = 3600 - Date().timeIntervalSince(start)
            return .rateLimited(resetIn: max(0, resetIn))
        }
        if dayCount >= dayLimit {
            let start = defaults.object(forKey: Key.dayStart) as? Date ?? Date()
            let resetIn = 86400 - Date().timeIntervalSince(start)
            return .rateLimited(resetIn: max(0, resetIn))
        }

        defaults.set(hourCount + 1, forKey: Key.hourCount)
        defaults.set(dayCount  + 1, forKey: Key.dayCount)
        return .allowed
    }

    // MARK: - Warning counter (for delay escalation)

    /// Number of spam-warnings the user received in the past 24 hours.
    var warningsLast24h: Int {
        resetExpiredWarnWindow()
        return defaults.integer(forKey: Key.warnings24h)
    }

    func recordWarning() {
        resetExpiredWarnWindow()
        let n = defaults.integer(forKey: Key.warnings24h)
        defaults.set(n + 1, forKey: Key.warnings24h)
        if defaults.object(forKey: Key.warnWindow) == nil {
            defaults.set(Date(), forKey: Key.warnWindow)
        }
    }

    // MARK: - Force-send abuse prevention

    /// Track rapid "Force send" taps; after 5 consecutive → 1-hour local ban.
    func recordForceSend() {
        let count = defaults.integer(forKey: Key.forceSend) + 1
        defaults.set(count, forKey: Key.forceSend)
        if count >= 5 {
            defaults.set(Date().addingTimeInterval(3600), forKey: Key.forceBanEnd)
            defaults.set(0, forKey: Key.forceSend)
        }
    }

    /// Whether the user is in a temporary force-send ban.
    var isForceSendBanned: Bool {
        guard let end = defaults.object(forKey: Key.forceBanEnd) as? Date else { return false }
        return Date() < end
    }

    var forceSendBanTimeRemaining: TimeInterval {
        guard let end = defaults.object(forKey: Key.forceBanEnd) as? Date else { return 0 }
        return max(0, end.timeIntervalSinceNow)
    }

    // MARK: - Window resets

    private func resetExpiredWindows() {
        let now = Date()

        if let start = defaults.object(forKey: Key.hourStart) as? Date,
           now.timeIntervalSince(start) >= 3600 {
            defaults.set(0,   forKey: Key.hourCount)
            defaults.set(now, forKey: Key.hourStart)
        } else if defaults.object(forKey: Key.hourStart) == nil {
            defaults.set(0,   forKey: Key.hourCount)
            defaults.set(now, forKey: Key.hourStart)
        }

        if let start = defaults.object(forKey: Key.dayStart) as? Date,
           now.timeIntervalSince(start) >= 86400 {
            defaults.set(0,   forKey: Key.dayCount)
            defaults.set(now, forKey: Key.dayStart)
        } else if defaults.object(forKey: Key.dayStart) == nil {
            defaults.set(0,   forKey: Key.dayCount)
            defaults.set(now, forKey: Key.dayStart)
        }
    }

    private func resetExpiredWarnWindow() {
        guard let start = defaults.object(forKey: Key.warnWindow) as? Date else { return }
        if Date().timeIntervalSince(start) >= 86400 {
            defaults.set(0,   forKey: Key.warnings24h)
            defaults.removeObject(forKey: Key.warnWindow)
        }
    }
}
