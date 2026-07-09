//
//  ShadowCompare.swift
//  Construct Messenger
//
//  Shadow-mode harness for de-risking behaviour changes in the session layer
//  (SESSION_COORDINATOR_REFACTOR_SPEC, risk-minimization step #3).
//
//  A risky cut-over (e.g. routing more END_SESSION paths through the rate limiter, or the
//  phase-mutating disposition unification) is first run in *shadow*: we compute the new
//  ("candidate") decision next to the current ("live") one, log when they disagree, and keep
//  acting on `live`. After a stretch of live TestFlight traffic with zero divergences, the
//  cut-over is safe. Nothing here changes production behaviour — `decide` always returns `live`.
//
//  MainActor-isolated: all session decisions run on the main actor, which also makes the
//  divergence bookkeeping free of data races without a lock.
//

import Foundation

@MainActor
enum ShadowCompare {

    /// First-seen divergence signatures, so a steady disagreement logs once instead of flooding.
    private static var seenSignatures: Set<String> = []

    /// Running divergence tally per label (telemetry: "are we at zero yet?").
    private(set) static var divergenceCounts: [String: Int] = [:]

    /// Cap on distinct signatures retained, so a pathological key space can't grow unbounded.
    private static let maxSignatures = 500

    /// Compare a `candidate` decision against the authoritative `live` one and **return
    /// `live`** (production behaviour is unchanged). On disagreement, tally it and log once per
    /// distinct `(label, key, live, candidate)` signature.
    ///
    /// - Parameters:
    ///   - label: stable identifier for this decision site (used for the per-label tally).
    ///   - key: per-subject discriminator (e.g. a contact id) — only its prefix is logged.
    ///   - live: the current, acted-upon value.
    ///   - candidate: the experimental value to evaluate against `live`.
    ///   - context: extra diagnostic text, evaluated only when a divergence is first logged.
    @discardableResult
    static func decide<T: Equatable>(
        _ label: String,
        key: String = "",
        live: T,
        candidate: T,
        context: @autoclosure () -> String = ""
    ) -> T {
        if candidate != live {
            divergenceCounts[label, default: 0] += 1
            let signature = "\(label)|\(key)|\(live)|\(candidate)"
            if seenSignatures.count < maxSignatures, seenSignatures.insert(signature).inserted {
                Log.info(
                    "SHADOW_DIVERGE[\(label)] live=\(live) candidate=\(candidate) key=\(key.prefix(8))… \(context())",
                    category: "SessionShadow"
                )
            }
        }
        return live
    }

    /// Total divergences observed for `label` this process lifetime (0 == safe to cut over).
    static func divergences(for label: String) -> Int {
        divergenceCounts[label] ?? 0
    }

    /// Reset all shadow state (tests / a fresh measurement window).
    static func reset() {
        seenSignatures.removeAll()
        divergenceCounts.removeAll()
    }
}
