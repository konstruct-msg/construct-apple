//
//  StreamHeartbeatSchedule.swift
//  Construct Messenger
//
//  When the client speaks first on a freshly opened stream.
//
//  A gRPC server-streaming handler does not flush response headers until it has something to
//  send. Our own `NetworkTiming` says so, in the note explaining why the VEIL accept timeout is
//  20s: "gRPC server bidi-stream handlers commonly don't flush initial response headers until the
//  first Send() (or until they receive the first client heartbeat). With our 25s client heartbeat
//  interval, 'no headers yet' is normal for ~25s on a quiet stream — even on a healthy channel."
//
//  The heartbeat loop slept *before* its first send, so after subscribing the client said nothing
//  for 25 seconds. On a chat with no queued backlog the server therefore had nothing to answer,
//  flushed no headers, and the direct-path accept timeout — 2.0s — declared the transport dead.
//  Every reconnect repeated it. The device could send (unary RPCs carry their own response) but
//  could never receive.
//
//  Device logs, 2026-08-10 17:31–17:35, two phones on one Wi-Fi with VPN and VEIL off:
//
//      17:32:04  sendMessage … event=rpc-ok(via=direct, 229ms)      ← unary, same host:port
//      17:32:13  openStream transport=H2 → ams.konstruct.cc:443
//      17:32:15  MessageStream open timed out — reconnecting        ← stream, 2000ms, same channel
//
//  229ms for a unary against 2000ms not being enough for a stream is not a blocked host and not
//  DPI. The peer device was reachable throughout — it was on VEIL, whose accept budget is 20s,
//  and its stream stayed up for minutes. The asymmetry the user saw ("messages go out but never
//  come back") was one device on a 2s budget and the other on a 20s one, not a direction.
//
//  So: speak first. One heartbeat the moment the stream opens gives the server something to
//  answer within one round-trip, which makes "accepted" a measurement of the transport instead of
//  a measurement of whether anyone happened to have mail waiting.
//
//  And only then (2026-10-13). The client also sent one every 25 s, which nothing needed: the
//  server answers the open itself (`send_initial_heartbeat_ack`) and then sends its own heartbeat
//  on an idle stream (messaging-service `grpc.rs`), and the stale-stream watchdog is fed by any
//  heartbeat from the server, not by answers to ours. What the periodic one did add was a second
//  fixed period on the wire — a small record every 25.0 s beside the server's — that an observer
//  can match without reading anything (vault `security/konstrukt-unobservability-map.md`). The
//  one at open stays: it costs nothing and covers a server older than its own first heartbeat.
//

import Foundation

enum StreamHeartbeatSchedule {

    /// How long to wait before emitting heartbeat number `index` (0-based) on a stream that has
    /// just opened; nil when there is no such heartbeat.
    ///
    /// Zero for the first one, and nothing after it. A separate function because the original bug
    /// was a `sleep` sitting one line above a `send` — invisible in review, and fatal only in
    /// combination with a timeout defined in a different file.
    static func delayBeforeHeartbeat(index: Int) -> TimeInterval? {
        index <= 0 ? 0 : nil
    }
}
