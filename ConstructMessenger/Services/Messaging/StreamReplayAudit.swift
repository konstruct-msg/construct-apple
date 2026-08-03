//
//  StreamReplayAudit.swift
//  Construct Messenger
//
//  Answers one question, and only from evidence: when the server delivers a message we have
//  already seen, who asked for it?
//
//  A device log showed ~97 incoming messages given up in a session where the two testers had
//  exchanged far fewer than that, alongside 3841 already-processed skips and 2566 receipts for
//  ~107 messages. Two explanations produce that shape and they have opposite fixes:
//
//    1. The server ignores `SubscribeRequest.since_cursor` and replays the conversation from the
//       beginning on every connect. Harmless with ten testers; with a thousand concurrent users
//       every reconnect storm becomes a full re-read of every backlog.
//    2. Our own resume cursor is stuck. `StreamCursorTracker` advances only over a contiguous run
//       of durably-handled entries and stalls rather than skip one — safe by design (the server
//       re-delivers, the client dedups) but the stall is silent, and a single entry stuck at the
//       head costs the whole backlog again on every reconnect.
//
//  The two are indistinguishable from a redelivery count, which is why counting redeliveries was
//  never going to settle it. They are trivially distinguishable from the cursors themselves:
//
//    * A message whose stream id is **strictly below the cursor we sent** is one the server had
//      been told we already have. Only hypothesis 1 produces that. (An entry at exactly the
//      cursor is an inclusive resume — an off-by-one, counted separately, accused of nothing.)
//    * All ids above the cursor we sent, but that cursor **unchanged across reconnects**, is
//      hypothesis 2 — and `StreamCursorTracker.headBlocker()` then names the entry responsible.
//
//  Not `#if DEBUG`: the question is about production load, and the run that will answer it is a
//  TestFlight build. The cost is two integers per stream and one comparison per delivered message.
//

import Foundation

@MainActor
final class StreamReplayAudit {

    static let shared = StreamReplayAudit()

    private var sentCursor: String?
    /// How many consecutive streams have opened with the same `since_cursor`. A cursor that does
    /// not move while messages keep arriving is the client-side stall.
    private var unchangedStreak = 0
    private var streamOpenedAt = Date()
    private var delivered = 0
    private var replayedBelowCursor = 0
    /// Entries at exactly the cursor we sent — an inclusive resume, not a replay. Counted apart so
    /// an off-by-one never gets reported as the scaling problem.
    private var boundaryEntries = 0
    private var firstOffender: (messageId: String, cursor: String)?
    /// Logged once per launch — an id shape we cannot parse is a reason to say nothing about the
    /// server, not a reason to repeat that we cannot say it.
    private var warnedAboutCursorFormat = false

    private init() {}

    // MARK: - Stream lifecycle

    func streamOpened(sinceCursor: String?) {
        if let sinceCursor, sinceCursor == sentCursor {
            unchangedStreak += 1
        } else {
            unchangedStreak = 0
        }
        sentCursor = sinceCursor
        streamOpenedAt = Date()
        delivered = 0
        replayedBelowCursor = 0
        boundaryEntries = 0
        firstOffender = nil

        let cursorText = sinceCursor.map { String($0.prefix(20)) } ?? "none (full backlog requested)"
        if unchangedStreak >= 2, let blocker = StreamCursorTracker.shared.headBlocker() {
            Log.error(
                "STREAM_REPLAY: since_cursor has not moved for \(unchangedStreak + 1) connects (\(cursorText)) — held by \(blocker.messageId.prefix(8))… state=\(blocker.state) for \(Int(blocker.age))s. Every reconnect re-reads the backlog from here.",
                category: "StreamReplay"
            )
            PerformanceMetrics.shared.record(.streamCursorStalled, label: blocker.state)
        } else {
            Log.info("STREAM_REPLAY: subscribe since_cursor=\(cursorText)", category: "StreamReplay")
        }
    }

    /// One server-delivered stream entry.
    func delivery(messageId: String, cursor: String?) {
        delivered += 1
        guard let cursor, let sentCursor else { return }
        guard let order = Self.compare(cursor, sentCursor) else {
            if !warnedAboutCursorFormat {
                warnedAboutCursorFormat = true
                Log.info(
                    "STREAM_REPLAY: stream ids are not <millis>-<seq> (\(cursor.prefix(24))) — replay-below-cursor cannot be judged",
                    category: "StreamReplay"
                )
            }
            return
        }
        switch order {
        case .descending:
            return                          // above the cursor: ordinary new traffic
        case .same:
            // The boundary entry itself. An inclusive resume (XRANGE from the id rather than
            // XREAD after it) returns exactly this one and nothing else — a harmless off-by-one,
            // not a backlog replay, so it must not be reported as one.
            boundaryEntries += 1
        case .ascending:
            replayedBelowCursor += 1
            if firstOffender == nil {
                firstOffender = (messageId, cursor)
                Log.error(
                    "STREAM_REPLAY: server sent \(messageId.prefix(8))… at cursor \(cursor.prefix(20)), BELOW the \(sentCursor.prefix(20)) we subscribed with — since_cursor is not being honoured",
                    category: "StreamReplay"
                )
                PerformanceMetrics.shared.record(.streamReplayBelowCursor, label: String(messageId.prefix(8)))
            }
        }
    }

    func streamClosed() {
        guard delivered > 0 else { return }
        let seconds = Int(Date().timeIntervalSince(streamOpenedAt))
        let boundary = boundaryEntries > 0 ? ", \(boundaryEntries) at the boundary (inclusive resume)" : ""
        if replayedBelowCursor > 0 {
            Log.error(
                "STREAM_REPLAY: stream closed after \(seconds)s — \(delivered) entries, \(replayedBelowCursor) below the cursor we sent\(boundary) (server-side replay)",
                category: "StreamReplay"
            )
        } else {
            Log.info(
                "STREAM_REPLAY: stream closed after \(seconds)s — \(delivered) entries, none below the cursor we sent\(boundary)",
                category: "StreamReplay"
            )
        }
    }

    // MARK: - Cursor ordering

    enum Order { case ascending, same, descending }

    /// Order two Redis stream ids (`<millis>-<seq>`). nil when either is not that shape — an
    /// unrecognised id must not be reported as a server fault.
    ///
    /// String comparison would be wrong: `"9999999999999-0" < "10000000000000-0"` lexicographically
    /// but not in time, and the seq part is not zero-padded at all.
    static func compare(_ lhs: String, _ rhs: String) -> Order? {
        guard let l = StreamId(lhs), let r = StreamId(rhs) else { return nil }
        if l == r { return .same }
        return l < r ? .ascending : .descending
    }

    private struct StreamId: Comparable {
        let millis: Int64
        let seq: Int64

        init?(_ id: String) {
            let parts = id.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let millis = Int64(parts[0]),
                  let seq = Int64(parts[1])
            else { return nil }
            self.millis = millis
            self.seq = seq
        }

        static func < (lhs: StreamId, rhs: StreamId) -> Bool {
            lhs.millis != rhs.millis ? lhs.millis < rhs.millis : lhs.seq < rhs.seq
        }
    }
}
