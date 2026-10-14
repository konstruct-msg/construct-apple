//
//  AlertDecision.swift
//  Konstruct Notifications (also compiled into the app, where its tests run)
//
//  What the notification extension does with the alert it was handed, decided from what its fetch
//  found and what the core's peek said of each delivery (construct-docs
//  decisions/notification-extension-reads-only.md). The one rule: an alert is dropped only when
//  every delivery the push could be about is a protocol frame. Every doubt shows it, because a
//  missed message is worse than a stray banner.
//

import Foundation

/// What the fetch came back with, before any peek.
enum PendingFetchOutcome: Equatable {
    /// The fetch did not complete: network, an expired token, the time budget. Nothing is known.
    case failed
    /// The page the server returned. `hasMore` means it was not everything waiting; `unsealed`
    /// counts deliveries with no `SealedInner`, which the peek cannot read.
    case fetched(hasMore: Bool, unsealed: Int)
}

enum AlertDecision: Equatable {
    /// Show the alert as it came. `reason` is for the log, never for the user.
    case show(reason: String)
    /// Every delivery was a protocol frame. Dropped only where the filtering entitlement allows;
    /// elsewhere the caller shows it and logs that it would have hidden it.
    case hide(controlFrames: Int)

    static func decide(fetch: PendingFetchOutcome, verdicts: [PeekVerdict]) -> AlertDecision {
        guard case let .fetched(hasMore, unsealed) = fetch else {
            return .show(reason: "fetch failed")
        }
        if hasMore { return .show(reason: "more waiting than one page") }
        if unsealed > 0 { return .show(reason: "\(unsealed) not sealed") }

        var control = 0
        for verdict in verdicts {
            switch verdict {
            case .visible: return .show(reason: "a message")
            case .unreadable: return .show(reason: "unreadable")
            case .control: control += 1
            case .alreadyHandled: continue
            }
        }
        // Nothing new at all: the app already took what the push announced, or the push raced
        // the fetch. The banner may be the only notice of a message read elsewhere — shown.
        guard control > 0 else { return .show(reason: "nothing new") }
        return .hide(controlFrames: control)
    }
}
