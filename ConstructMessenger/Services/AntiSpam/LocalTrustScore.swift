//
//  LocalTrustScore.swift
//  Construct Messenger
//
//  On-device trust score for the current user.  Persists across sessions.
//  Score represents how "trusted" the sender is from a behavioural perspective.
//

import Foundation

/// Behavioural trust score for the local user.
///
/// - `0.0` — highly untrusted (repeated warnings / reports)
/// - `0.3` — new account default
/// - `1.0` — long-standing trusted account
///
/// Score is stored in `UserDefaults` and survives app restarts.
final class LocalTrustScore {

    static let shared = LocalTrustScore()

    // MARK: - Persistence

    private let key = "com.construct.antispam.trustScore"
    private let defaults = UserDefaults.standard

    // MARK: - Score

    /// Current trust score in [0.0, 1.0].  Defaults to 0.3 (new account).
    private(set) var score: Float {
        get { Float(defaults.double(forKey: key)) }
        set { defaults.set(Double(newValue), forKey: key) }
    }

    private init() {
        // Initialise to 0.3 on first launch (no stored value yet)
        if defaults.object(forKey: key) == nil {
            score = 0.3
        }
    }

    // MARK: - Mutations

    /// Call when a message was delivered successfully.
    func recordSuccess() {
        score = min(1.0, score + 0.002)
    }

    /// Call when the user is shown a spam-warning UI.
    func recordWarning() {
        score = max(0.0, score - 0.1)
    }

    /// Call when a contact reports this user as spam.
    func recordReport() {
        score = max(0.0, score - 0.2)
    }

    /// Reset to new-account default (e.g. after account deletion / re-registration).
    func reset() {
        score = 0.3
    }
}
