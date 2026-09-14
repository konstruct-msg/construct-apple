//
//  TokenSpendUnitStore.swift
//  Construct Messenger
//
//  A retry is the same logical message, so it must not buy a second token.
//
//  Measured 2026-09-11 on two devices: 71 sealed sends, 71 tokens, zero "covered by unit" lines.
//  One message — `fbb24a8d` — cost six. Two of those six were `MessageRetryManager` attempts 1 and
//  2 of the *same* body, and `maxMessageRetryAttempts` is 3, so a message the network dislikes can
//  cost four tokens on the primary path alone. That is the worst possible moment to charge more:
//  the retries are caused by a bad connection, and a bad connection is also what makes wallet
//  replenishment fail (seven `replenishment failed [transport error]` lines on one device in the
//  same window). Spend accelerates exactly while income stops.
//
//  The server already has the mechanism. `redeem_token_checked` writes
//  `pp:unit:{sha256(spend_id | recipient_user_id)}` for **2 h** on the first paid envelope, and any
//  later envelope with the same pair is `UnitCovered` — no token, up to 256 envelopes. Nothing
//  there is chunk-specific: a retry sent nine minutes later is simply a later envelope of the same
//  unit. All that was missing is a client that remembers the id across the gap.
//
//  So this store holds `(spendId, paidAt)` under the base message id. It records a unit only once
//  it has actually been **paid** — an unpaid id buys nothing, because the retry would have to spend
//  a token anyway, and storing it would only invite a reuse that quietly fails.
//
//  The window is deliberately shorter than the server's 2 h (see
//  `TokenSpendUnitRetention.coverageWindow`). A client that reuses an id the server has just
//  expired gets `NeedToken` under warn — harmless — but a rejected send under enforce, recovered
//  only by the extra round trip in `StealthSendRecovery`. Reusing slightly less than we could is
//  the cheap side of that trade.
//

import Foundation

/// Pure retention arithmetic, so the two decisions this store makes are testable without
/// UserDefaults, a clock, or a main actor (`decisions/testing-by-pure-decision.md`).
enum TokenSpendUnitRetention {

    /// Key prefix for every stored unit. Also the sweep's only handle on the keyspace.
    static let keyPrefix = "construct.tokenSpendUnit.v1."

    /// How long a paid unit may be reused.
    ///
    /// The server holds `pp:unit:` for 2 h (`token_redeem.rs` `SPEND_UNIT_TTL`). 90 minutes leaves
    /// half an hour of margin for a client clock that runs fast, a send that took a while to reach
    /// Redis, and the gap between `paidAt` (when we attached the token) and the server's `EX`
    /// (when it wrote the key). Raising this to 2 h would not save more tokens in practice —
    /// retries happen in minutes — and would trade that margin away for nothing.
    static let coverageWindow: TimeInterval = 90 * 60

    /// May a unit paid at `paidAt` still cover an envelope sent at `now`?
    ///
    /// A `paidAt` in the future is not usable: it means the clock moved backwards between the send
    /// and the retry, and the elapsed time we would be reasoning about is unknown rather than
    /// small. Falling back to paying is correct whenever we cannot tell.
    static func isUsable(paidAt: TimeInterval, now: TimeInterval) -> Bool {
        let age = now - paidAt
        return age >= 0 && age < coverageWindow
    }

    /// Keys whose record can no longer cover anything, for the launch sweep.
    ///
    /// An entry that fails to decode has no readable `paidAt` and can never be used again, so it
    /// is expired by definition — otherwise a corrupt write would sit in UserDefaults forever.
    static func expiredKeys(_ entries: [(key: String, paidAt: TimeInterval?)], now: TimeInterval) -> [String] {
        entries.filter { entry in
            guard let paidAt = entry.paidAt else { return true }
            return !isUsable(paidAt: paidAt, now: now)
        }
        .map(\.key)
    }
}

/// Remembers the paid spend unit of a logical message so its retries ride on the same redemption.
@MainActor
enum TokenSpendUnitStore {

    private struct Entry: Codable {
        let spendId: Data
        let paidAt: TimeInterval
    }

    /// Keyed by message **and** recipient because the server's unit is
    /// `sha256(spend_id | recipient_user_id)`: an id is only ever covered for the account it was
    /// opened against. The base message id alone would be enough today, since a message has one
    /// recipient — but then the key would be narrower than the thing it stands for, and the next
    /// person to add a forward or a re-send to someone else would find that out in production.
    private static func key(baseMessageId: String, recipientId: String) -> String {
        "\(TokenSpendUnitRetention.keyPrefix)\(baseMessageId.lowercased())|\(recipientId.lowercased())"
    }

    /// Records a unit that has actually paid. A unit that never attached a token is ignored:
    /// there is no redemption for a retry to ride on, so remembering it would be a promise the
    /// server never made.
    static func remember(_ unit: TokenSpendUnit, baseMessageId: String, recipientId: String, now: Date = Date()) {
        guard !unit.shouldAttemptPayment else { return }
        let entry = Entry(spendId: unit.spendId, paidAt: now.timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        UserDefaults.standard.set(data, forKey: key(baseMessageId: baseMessageId, recipientId: recipientId))
    }

    /// The paid unit for this message, or nil when there is none or it is past the window.
    ///
    /// Returned already marked paid, which is the whole point: `shouldAttemptPayment` is then
    /// false and every envelope of the retry carries the id without buying anything.
    static func paidUnit(baseMessageId: String, recipientId: String, now: Date = Date()) -> TokenSpendUnit? {
        let k = key(baseMessageId: baseMessageId, recipientId: recipientId)
        guard let data = UserDefaults.standard.data(forKey: k),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        guard TokenSpendUnitRetention.isUsable(paidAt: entry.paidAt, now: now.timeIntervalSince1970) else {
            UserDefaults.standard.removeObject(forKey: k)
            return nil
        }
        return TokenSpendUnit.restoredPaid(spendId: entry.spendId)
    }

    /// The message is delivered or abandoned — nothing will ride on this unit again.
    static func forget(baseMessageId: String, recipientId: String) {
        UserDefaults.standard.removeObject(forKey: key(baseMessageId: baseMessageId, recipientId: recipientId))
    }

    /// Drops every record past its window. Called once at launch, for the same reason
    /// `OutgoingWirePayloadStore.sweepExpired` is: the per-key expiry check only ever runs for a
    /// key someone asks for by id, so a message that was never retried is never even looked at.
    static func sweepExpired(now: Date = Date()) {
        let defaults = UserDefaults.standard
        let keys = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(TokenSpendUnitRetention.keyPrefix) }
        guard !keys.isEmpty else { return }

        let entries: [(key: String, paidAt: TimeInterval?)] = keys.map { k in
            guard let data = defaults.data(forKey: k),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return (k, nil) }
            return (k, entry.paidAt)
        }
        for k in TokenSpendUnitRetention.expiredKeys(entries, now: now.timeIntervalSince1970) {
            defaults.removeObject(forKey: k)
        }
    }
}
