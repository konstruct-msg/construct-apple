//
//  OfflineFetchCoalescer.swift
//  Construct Messenger
//
//  Whether a silent push needs a fetch of its own, or is already answered by one.
//

import Foundation

/// A `new_message` silent push carries no message — it only says "there is something on the
/// server for you". Fifty of them say exactly the same thing, and one fetch answers all fifty:
/// `GetPendingMessages` returns the whole backlog from the cursor, not one message.
///
/// Build 585, device 6bf51980, the first seven seconds after launch:
///
///     Silent push received … 49        iOS delivers the whole backlogged queue at once
///     Starting quick message fetch 49  strictly one fetch per push
///     Offline fetch from cursor 49     every one from cursor=1786093333419-0
///     Processing 46…49 offline messages   … the same page, forty-nine times
///     Saved 0 new messages to Core Data   … forty-nine times
///
/// Seventeen of them landed in a single second. That is ~2 300 trips through the routing
/// pipeline for 47 distinct messages, on a device already reporting `thermal=serious`.
/// The existing "foreground MessageStream is live" guard could not help: at launch the stream
/// is not up yet, which is exactly when the backlog of pushes arrives.
///
/// The rule is about coverage, not rate. A fetch that *started* at or after a push arrived
/// necessarily asked the server a question newer than the event that push announced, so it
/// covers that push. Nothing here is dropped on a timer: when no in-flight fetch covers a push,
/// one follow-up is requested, and the follow-up starts after the whole burst has landed.
enum OfflineFetchCoalescer {

    enum Admission: Equatable {
        /// No fetch covers this push and none is running — go.
        case start
        /// A fetch is running but it started before this push, so it may not carry the news.
        /// Ask for exactly one fetch after it finishes; further pushes fold into the same one.
        case requestFollowUp
        /// A fetch already started after this push arrived. It sees everything the push meant.
        case alreadyCovered
    }

    /// - Parameters:
    ///   - pushArrivedAt: when this silent push reached the app.
    ///   - lastFetchStartedAt: when the most recent fetch *began*, running or finished. Start,
    ///     not completion: the request is what asks the server, so a fetch that began after the
    ///     push is the one that answers it, whenever it happens to return.
    ///   - isFetchInFlight: whether that fetch is still running.
    static func admit(
        pushArrivedAt: Date,
        lastFetchStartedAt: Date?,
        isFetchInFlight: Bool
    ) -> Admission {
        if let startedAt = lastFetchStartedAt, startedAt >= pushArrivedAt {
            return .alreadyCovered
        }
        return isFetchInFlight ? .requestFollowUp : .start
    }
}
