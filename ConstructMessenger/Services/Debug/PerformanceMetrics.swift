//
//  PerformanceMetrics.swift
//  Construct Messenger
//
//  Debug-only performance measurement for latency analysis.
//  All instrumentation is compiled out in Release builds.
//

import Foundation
import os.signpost

// MetricEvent must be defined in all build configs so call sites compile in Release.
// The Release PerformanceMetrics stubs are @inline(__always) no-ops — zero overhead.

// MARK: - Event Types

enum MetricEvent: String {
    // Message receive pipeline
    case envelopeArrived        = "envelope_arrived"
    case decryptStart           = "decrypt_start"
    case decryptEnd             = "decrypt_end"
    case uiDisplayed            = "ui_displayed"

    // Session
    case sessionInitStart       = "session_init_start"
    case sessionInitEnd         = "session_init_end"
    case sessionRestoreStart    = "session_restore_start"
    case sessionRestoreEnd      = "session_restore_end"

    // Core Data
    case coreDataSaveStart      = "core_data_save_start"
    case coreDataSaveEnd        = "core_data_save_end"
    case coreDataSaveFailed     = "core_data_save_failed"

    // Network
    case grpcConnectStart       = "grpc_connect_start"
    case grpcConnectEnd         = "grpc_connect_end"
    case veilProxyStartBegin     = "veil_proxy_start_begin"
    case veilProxyStartEnd       = "veil_proxy_start_end"
    case streamOpenStart        = "stream_open_start"
    case streamOpenEnd          = "stream_open_end"

    // Routing/failover
    case streamOpenFastFailover       = "stream_open_fast_failover"

    // Calls
    case callSetupStart         = "call_setup_start"
    case callSetupEnd           = "call_setup_end"
    case callSignalOpenStart    = "call_signal_open_start"
    case callSignalOpenEnd      = "call_signal_open_end"

    // Stealth sealed sender (stealth-sealed-sender-v2 Phase 4) — local DEBUG-only
    // counters, never transmitted. Deliberately not production telemetry: a feature
    // whose point is minimizing what the server observes about a user shouldn't grow
    // a client→server monitoring channel as a side effect.
    case stealthSealFailure     = "stealth_seal_failure"
    case stealthUnsealFailure   = "stealth_unseal_failure"
    // sealed-sender-resilience Stage 1: a sealed message whose sender we recovered
    // (unseal ok) but could not attest (cert expired/invalid/no bundle key) — delivered
    // anyway via the ratchet instead of dropped. `label` carries the reason.
    case stealthUnvouchedDelivery = "stealth_unvouched_delivery"
    // Unseal itself failed (no sender/payload recoverable): held for one redelivery
    // before the eventual drop.
    case stealthUnsealDefer     = "stealth_unseal_defer"
    // Send-side: policy wanted a Privacy Pass token but the wallet was empty, so the
    // message was sealed and sent WITHOUT a token — anti-abuse degraded, anonymity
    // intact. Makes the silent token-less degradation observable (empty-wallet symptom).
    case stealthTokenlessSend   = "stealth_tokenless_send"
    // Send-side: server rejected the sealed send under enforce
    // (FAILED_PRECONDITION "privacy_pass:{label}") — counted per rejection, before
    // the one-shot replenish+retry. label = rejection reason from the server.
    case stealthEnforceRejected = "stealth_enforce_rejected"
    // (The send-side degraded-delivery downgrade is already counted by
    // `stealthSealFailure` above — no separate event needed.)

    /// MessageRouter fallthrough: Rust returned no routable action for a *known*
    /// control/signal content type (session control, call, receipt, sender-sync).
    /// Was silent INFO for four days while sealed END_SESSION/SRI were dropped —
    /// keep this ERROR-path countable. `label` carries `ct=<n>`.
    case noRoutingDecisionControl = "no_routing_decision_control"

    // MARK: Silent semantic-divergence detectors (iOS audit 2026-08-02)
    // These exist so a dual-meaning / dual-store mismatch cannot hide as DEBUG/INFO.

    /// A multi-chunk KNST reassembly was **dropped without ever completing** — the message is
    /// lost, and since the ratchet already advanced and the cursor already moved, it is lost for
    /// good. `label` = message id prefix.
    ///
    /// This replaced `chunk_reassembly_incomplete` on 2026-08-03. That metric fired on every
    /// *intermediate* chunk, so a 12-chunk photo raised it eleven times and a real loss raised it
    /// zero — the counter measured traffic, not failure, while the event it was named for went
    /// unrecorded. See sessions/2026-08-03-inverted-chunk-logging.md.
    case chunkReassemblyExpired = "chunk_reassembly_expired"

    /// Older-batch load via the infinite-scroll path (`.indicatorAppeared`). After
    /// `shouldLoadOlderHistory` this should no longer fire on bare chat entry (the LazyVStack top
    /// materialisation that used to grow 30 → 50 during opening — TODO 34). Residual ticks are a
    /// real near-top scroll or a short-window `contentFits` fill. `label` = message count on screen.
    case loadMoreUnprompted = "load_more_unprompted"

    /// An END_SESSION or SESSION_RESET_INIT carrier reached the ordinary wire-payload path instead
    /// of early-exiting. The core would unpack the sentinel as a wire payload and never archive the
    /// session — a desync that only heals by luck. `label` = the content type that got through.
    case controlCarrierReachedWirePath = "control_carrier_reached_wire_path"

    /// A delivery receipt was NOT re-sent because one for the same message went out inside the
    /// window (`ReceiptResendThrottle`). Under a healthy stream this stays near zero; a large
    /// number is the redelivery storm being absorbed instead of amplified. `label` = call site.
    case receiptResendThrottled = "receipt_resend_throttled"

    /// More than one message id rode out in a single receipt (`DeliveryReceiptBatcher`). Every tick
    /// is `label - 1` encrypt+ratchet+RPC cycles that did not happen; on a healthy stream this
    /// stays near zero because receipts arrive alone. `label` = ids in that receipt.
    case receiptsBatched = "receipts_batched"
    /// A redelivery dropped before the sealed-sender unseal. The counter is the point: it is the
    /// measure of how much work the server's cursor replay is costing this device, and it should
    /// track `redelivery_skipped ≈ incoming` while the server keeps replaying below the watermark.
    case redeliverySkippedBeforeUnseal = "redelivery_skipped_before_unseal"

    /// A message row was persisted whose entire body is a bare UUID — an identifier where text
    /// belongs, i.e. a service payload reaching the transcript. `label` = the writing call site
    /// (`file:line`), which is the whole point: the shape was observed on device before any
    /// candidate path could be confirmed. See `Message.applyStoredEncryption`.
    case identifierPersistedAsMessageBody = "identifier_persisted_as_message_body"

    /// The server delivered a stream entry whose id is strictly below the `since_cursor` we
    /// subscribed with — it was told we already had that message and sent it anyway. Distinct
    /// from the stall below on purpose: this one is the server re-reading the backlog, which at
    /// scale multiplies every reconnect by the size of every user's history. `label` = message id
    /// prefix. See `StreamReplayAudit`.
    case streamReplayBelowCursor = "stream_replay_below_cursor"

    /// Our own resume cursor has not moved across three consecutive stream opens while a head
    /// entry stays unresolved. Redelivery here is ours to stop, not the server's: the tracker
    /// stalls rather than skip an unhandled entry, which is correct, but a permanently stuck head
    /// makes the server resend everything behind it on every reconnect. `label` = blocker state
    /// (`pending` / `deferred`).
    case streamCursorStalled = "stream_cursor_stalled"

    /// The core answered a `checkAckInDb` round-trip with the verdict "duplicate" — a terminal,
    /// benign disposition. Counted rather than logged loud: under redelivery this is the single
    /// highest-volume event on the receive path (6296 of 6302 fallthroughs in the 2026-08-04 run),
    /// and it is exactly the traffic the server should stop sending, not something we did wrong.
    /// `label` = `msgNum=<n>`.
    case duplicateAfterAckCheck = "duplicate_after_ack_check"

    /// A `checkAckInDb` round-trip came back empty while our answer was "not processed". Empty is
    /// the core's encoding for three different verdicts (`orchestrator.rs`): duplicate, init lock
    /// held, END_SESSION cooldown. Our own answer rules out the first, so this is one of the two
    /// "come back later" cases — the message was dropped without a routing decision and only the
    /// server's redelivery brings it back.
    ///
    /// Measured 2026-08-05 (build 577): it fires, five times inside one session re-establishment,
    /// on ordinary message bodies (msgNum 0-3) — and none of them came back. The cursor policy was
    /// `.durable` while the log line promised redelivery, so the watermark advanced past them. Now
    /// `.deferred`: both causes of an empty verdict are transient, so holding the cursor is what
    /// "pending redelivery" was always supposed to mean.
    case ackCheckResumedWithoutDecision = "ack_check_resumed_without_decision"

    /// MessageRouter fallthrough for an ordinary message body: the core returned actions, none of
    /// them routable, and no row was written. Sibling of `noRoutingDecisionControl`.
    ///
    /// Named for the message, not for "duplicate" as originally planned: once duplicates are
    /// answered above by `duplicateAfterAckCheck`, what reaches the fallthrough is the genuinely
    /// undecided remainder (`NotifyError` for QUEUE_FULL / ROUTING_ERROR, suppressed heal). A
    /// counter called `duplicate` would have gone to zero and read like a fix. `label` = action list.
    case noRoutingDecisionMessage = "no_routing_decision_message"

    /// The core required a durable ACK record (`CfeAction.persistAck`) and the routing pass ended
    /// `.durable` without one being written. Replaces `persistAckPlatformOnlyMemory`, which fired
    /// on every decrypted message and so counted traffic rather than the gap it was named for —
    /// the same inversion `chunkReassemblyExpired` corrected. `label` = `msgNum=<n>`.
    case persistAckWithoutDurableWrite = "persist_ack_without_durable_write"

    /// An incoming message the ratchet could not read was held behind the tie-break confirm gate
    /// instead of being answered — a decrypt failure (`dr_fail_pending_confirm`) or a heal request
    /// (`heal_pending_confirm`) arriving while our own SESSION_RESET_INIT is unacked. Benign and
    /// expected during a re-init; it is the volume gauge for how much traffic a confirm window
    /// costs. The labels replace `undeliveredNoReceipt(stale_init)`, which counted the same event
    /// back when it was a permanent discard. `label` = reason.
    ///
    /// A third label, `peer_init`, was retired on 2026-08-21 with the pre-decryption hold that
    /// emitted it. It counted `messageNumber == 0`, which named a fresh sending chain rather than a
    /// handshake, and its largest single contributor was the peer's own `session_ready`.
    case confirmHold = "confirm_hold"

    /// The confirm hold hit its per-peer cap (100) and a message was genuinely dropped. This is
    /// the only losing branch left in the hold path, so it is the one that must be loud — the
    /// distinction rule 1a exists for: `confirmHold` is "not yet", this is "never".
    /// `label` = reason.
    case confirmHoldOverflow = "confirm_hold_overflow"

    /// A primary VEIL capability was refused before storing: the relay address the *server*
    /// chose is vouched for by no anchor outside its control, its SPKI disagrees with the pinned
    /// one, or the blob failed its issuer check. Previously the first two could not refuse
    /// anything — the ticket was stored and the SPKI compared afterwards, as a log line.
    ///
    /// `label` is the reason only, never the address or a key: the point of this layer is that
    /// nobody learns where a user was steered, and a local counter is no exception.
    case veilPrimaryCapabilityRejected = "veil_primary_capability_rejected"

    /// A SENDER_SYNC arrived without the fields needed to route it, so the copy of a message this
    /// user sent from another device is dropped and never appears in the transcript here.
    ///
    /// Not repairable here, and not a relay bug: the server blanks `conversation_id` and
    /// `sender_device` deliberately (server-visible metadata must not carry E2E semantics), while
    /// SENDER_SYNC routes on exactly those. Counted so the size of that contradiction is a number
    /// rather than a log line — this is how often multi-device sync silently did nothing.
    /// `label` = which fields were missing.
    case senderSyncUnroutable = "sender_sync_unroutable"

    /// A delivery addressed to our own account arrived on the peer path — `from == to == us` with
    /// a content type that is not SENDER_SYNC. That shape is one of our own sends handed back by
    /// the server's per-device fan-out, and until 2026-08-28 the receive path read it as a message
    /// from a contact called "us": a chat with ourselves, a tie-break against our own device, and
    /// a SESSION_RESET_INIT to ourselves that tore down a healthy session.
    ///
    /// `label` = the outer content type, which is the only thing that distinguishes the carriers.
    /// A non-zero count after the receipt suppression means something else still addresses us.
    case selfAddressedDropped = "self_addressed_dropped"

    /// A device of the recipient did not get its copy of a message the sender considers sent.
    ///
    /// The release gate for §C asks this to be zero, and until 2026-08-31 nothing could answer it:
    /// every way out of the fan-out logged at `info` and returned, so a device that never heard of
    /// a message was indistinguishable from an account that has only one. Observed 2026-08-28 — a
    /// second device linked at 11:14, the single bundle fetch after it timed out at 11:18, there
    /// was no retry, and the copy simply never existed.
    ///
    /// `label` = why, a closed set of five:
    /// `bundle_fetch_failed` (the fetch threw — the 2026-08-28 shape) · `no_bundles` (it returned
    /// an empty list) · `send_failed` (one device's send threw, the others still went) ·
    /// `no_sender_device` · `no_chunks`.
    ///
    /// **Counts occurrences, not devices**, and the distinction is the point rather than a
    /// shortcut: on `send_failed` the loop knows exactly which device it lost, but on the three
    /// fetch-side reasons the call that would have named the devices is the one that failed, so a
    /// device count there could only be a guess dressed as a measurement. The log line beside each
    /// one carries how many devices we believe the account has, from `PeerDevice`, which is a
    /// belief and is written as one.
    ///
    /// Not recorded when the plan is legitimately empty — a single-device recipient the primary
    /// send already covered is the overwhelmingly common case and is not a skip. Keeping those
    /// apart is why "no targets" logs at `debug` and does not come here.
    case fanoutDeviceSkipped = "fanout_device_skipped"

    /// A copy owed to a recipient's device will never be sent, and the queue has stopped trying.
    ///
    /// Separate from `fanoutDeviceSkipped` rather than another label on it, for two reasons. A
    /// skip is recoverable and a give-up is not, so folding them would make the §C gate — which
    /// asks for zero skips — unable to distinguish "retried and delivered" from "retried and lost".
    /// And `record` collapses an event's whole label breakdown once it exceeds eight distinct
    /// values, silently; the skip reasons already stand at six, so adding terminal outcomes there
    /// would put the breakdown one label away from disappearing without saying so.
    ///
    /// `label` = `exhausted` (five attempts, all failed) · `not_reconstructable` (the row is a
    /// media message, whose wire plaintext the persisted model cannot rebuild — a pre-existing
    /// limit of every retry path here, not one this queue introduces) · `no_row` (the message was
    /// deleted while the copy was owed, which is the one benign member of the set) ·
    /// `not_retryable` (the retry hit a missing device id or an empty chunk plan — not a transport
    /// failure, so trying again would meet the same wall).
    case fanoutRetryGaveUp = "fanout_retry_gave_up"

    /// The fast-UDP transport (engine-QUIC / native H3) was suppressed on this network because it
    /// failed to carry data. `label` = the ladder rung just armed (`rung1` 5min · `rung2` 1h ·
    /// `rung3` 24h), which is the gauge for "how permanently is QUIC blocked where this user is".
    ///
    /// Benign by itself — it means the fallback worked — so it stays a counter, not an ERROR (1a).
    /// What it answers is whether the ladder converges: a device that keeps re-arming `rung1` is a
    /// device whose evidence is being erased between attempts, which is the defect this replaced.
    case quicSuppressed = "quic_suppressed"

    /// A network path change reached a live fast-UDP stream. `migrated` = the QUIC connection was
    /// carried across and the stream kept running · `reconnected` = the migration was not confirmed
    /// and the stream was reopened, which is what always happened before 2026-08-24.
    ///
    /// The ratio is the gauge for whether QUIC's mobility is real on the networks users are on —
    /// it is one of the two reasons this transport exists, and until now nothing measured it.
    case quicPathMigration = "quic_path_migration"

    /// A sealed send found the wallet empty and waited for issuance. `served` = a token arrived in
    /// time · `timeout` = it did not · `backoff` = the issuer was refusing, so we did not wait.
    ///
    /// This is the gauge for the enforce readiness question. `served` is the share of sends that
    /// used to go token-less (and would be *rejected* under enforce) and no longer do; a rising
    /// `timeout` means issuance cannot keep up with the burst and the cap needs re-sizing, not the
    /// client; `backoff` counts sends the server was always going to refuse.
    case tokenWalletWait = "token_wallet_wait"

    /// MetricKit handed us a crash report. `label` = the crash class (signal / exception type),
    /// never a stack frame. Exists because TestFlight has been delivering device metadata with the
    /// payload withheld, so TODO 40 has had two theories and no evidence.
    case crashDiagnosticReceived = "crash_diagnostic_received"

    /// A message the confirm gate held turned out to belong to a peer session that a later
    /// handshake replaced, so it was acknowledged instead of re-routed.
    ///
    /// Benign — it is the gate doing its job — but it is the counter for the defect it replaced:
    /// replaying such an init drove `heal` → `manual_reset` and deleted a healthy session, which
    /// is what put "the encrypted session is out of sync" on screen three times in one hour of
    /// the build-579 run.
    case confirmReplaySuperseded = "confirm_replay_superseded"

    /// A SESSION_RESET_INIT arrived that we had already acted on — a server redelivery of the same
    /// init. Coalesced to an ACK now; before, both copies re-established, and the second archived
    /// the session the first had just built.
    case resetInitDuplicate = "reset_init_duplicate"

    /// The callee answered before the SDP offer arrived. `wait` = answered with no offer yet,
    /// `resumed` = the late offer finished the answer, `timeout` = it never came and the call was
    /// failed honestly. "There is an incoming call" and "here is its SDP" ride different channels
    /// (VoIP push vs the E2EE message stream) and CallKit is driven by the fast one, so `wait` is
    /// normal and expected; a `wait` with no matching `resumed` is the defect.
    case answerBeforeOffer = "answer_before_offer"

    /// A call signal arrived for a call that had already ended. Benign to drop, loud enough to
    /// count: the offer variant used to re-report the dead call to CallKit, producing a phantom
    /// incoming call from a peer who was not calling. `label` = signal kind.
    case callSignalAfterEnd = "call_signal_after_end"

    /// A VoIP push arrived for a call the E2EE offer had already created. Normal — the two race, and
    /// either can win. Counted because acting on it used to mean `begin()`, which replaced the
    /// `ActiveCall` and took the stored offer SDP and every buffered ICE candidate with it; the
    /// callee then answered into nothing and waited 45 s for an SDP it had held all along.
    case incomingPushDuplicate = "incoming_push_duplicate"

    /// A session handshake control (SRI / ping / ready) was abandoned mid-retry because the
    /// session it announces was replaced or destroyed between attempts. Sending it anyway told the
    /// peer to reset a session that had already been superseded — see the 2026-08-04 cascade in
    /// `sendSessionControlCore`. `label` = `<logTag>:replaced` | `<logTag>:gone`.
    case controlRetrySuperseded = "control_retry_superseded"

    /// A `checkAckInDb` action reached a handler other than `MessageRouter`, which owns the
    /// round-trip. Nothing answers it there any more, so the message does not route — loud on
    /// purpose: the previous behaviour (answer from a detached Task, discard the verdict) could
    /// consume the core's buffered message and throw its routing decision away. `label` = handler.
    case ackCheckOutsideRouter = "ack_check_outside_router"

    /// Rust asked us to tell the user's other devices that a session was reset, and we did not —
    /// the feature has no consumer (see `MultiDeviceSendCoordinator.broadcastSessionReset`).
    /// Counted so the gap is a number rather than a silent no-op: this is how often a working
    /// implementation would have fired, which is what decides whether it is worth building.
    case linkedDeviceResetNotifyUnimplemented = "linked_device_reset_notify_unimplemented"

    /// A terminal disposition that did NOT put the message in front of the user: dropped,
    /// undecryptable, superseded, or given up on. No receipt is sent — the stream cursor
    /// advances on its own (`StreamCursorTracker`, default `.durable`), and a `.delivered`
    /// receipt here would set a checkmark on the sender for something they never received.
    ///
    /// Replaces `receiptDeliveredOnFailure`, which counted those sends while they still
    /// happened. `label` = reason code (`fallthrough`, `init_fail`, `heal_exhausted`,
    /// `invalid_chunk`, `stale_pending`, `binary_init_discarded`,
    /// `tie_break_win`).
    case undeliveredNoReceipt = "undelivered_no_receipt"

    /// A durable ACK was written but the in-memory dedup cache could not be warmed, because
    /// the orchestrator core was not up. Correctness is unaffected — Core Data owns dedup and
    /// every reader falls through to it — but the hot-path guard is colder than intended.
    /// Should be zero in a normal run: `markProcessed` is only reached after a decrypt, which
    /// already requires the core. A non-zero count means that assumption is wrong somewhere.
    case ackCacheWarmSkippedNoCore = "ack_cache_warm_skipped_no_core"

    /// How a per-device copy addressed to the recipient's account was judged on arrival.
    /// `label` = `ours` · `foreign` · `undecidable`.
    ///
    /// The one that matters is `undecidable`: we cannot tell a sibling's copy from a copy sent by
    /// a peer device we never pinned, so it is opened, and opening a copy that was not ours costs
    /// a failed decrypt. That is the safe direction — discarding one loses a message from the
    /// transcript silently — but its *frequency* has never been measured, and the frequency is the
    /// whole case for putting the account id inside the session record so a cold start can decide
    /// without `PeerDeviceRegistry`.
    ///
    /// This counter exists so that decision is taken on a number. Until a run produces one,
    /// "add the field" and "leave it" are both guesses.
    case deviceCopyVerdict = "device_copy_verdict"
}

#if DEBUG

// MARK: - Metric Record

struct MetricRecord: Identifiable {
    let id = UUID()
    let timestamp: CFAbsoluteTime
    let event: MetricEvent
    let label: String       // e.g. messageId or userId prefix
    let value: Double?      // optional precomputed duration in ms

    var formattedTime: String {
        let date = Date(timeIntervalSinceReferenceDate: timestamp)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
}

// MARK: - Latency Sample

struct LatencySample: Identifiable {
    let id = UUID()
    let label: String
    let durationMs: Double
    let timestamp: CFAbsoluteTime

    var formattedDuration: String {
        String(format: "%.1f ms", durationMs)
    }
}

// MARK: - Performance Metrics Collector

/// Thread-safe ring-buffer collector for debug performance events.
/// Use `PerformanceMetrics.shared` — all methods are no-ops in Release.
final class PerformanceMetrics: @unchecked Sendable {

    static let shared = PerformanceMetrics()
    private init() {}

    // Ring buffer — last 200 raw events
    private let lock = NSLock()
    private var events: [MetricRecord] = []
    private let maxEvents = 200

    /// Monotonic per-event totals, kept beside the ring buffer because the two answer different
    /// questions and only one of them was ever asked.
    ///
    /// The buffer answers "what happened recently"; it holds 200 records shared by every event, so
    /// it cannot answer "how many times did this happen" — which is what every signal in
    /// `decisions/ios-semantic-divergence-signals.md` was added to answer. The 2026-08-04 run
    /// recorded `duplicate_after_ack_check` 6296 times, turning the buffer over thirty times, and
    /// the rare loud events the epic exists for are the first thing that eviction takes.
    private var totals: [MetricEvent: Int] = [:]

    /// Totals as of the last `changedSignalsSummary()`, so a quiet interval logs nothing.
    private var reportedTotals: [MetricEvent: Int] = [:]

    /// Per-label totals for the events whose label is a small closed set, and the events that have
    /// proven it is not.
    ///
    /// The split matters because for several gauges the event total answers nothing on its own:
    /// `token_wallet_wait` is the Privacy Pass enforce-readiness measurement (TODO 47) and the
    /// decision turns entirely on `served` vs `timeout` vs `backoff`. Other events label with an
    /// identifier — `msgNum=`, a message id, an action list — where a per-label map would grow
    /// without bound over a run and say nothing at the end of it.
    ///
    /// Which is which is discovered, not declared: an event that exceeds `maxLabelsPerEvent`
    /// distinct labels collapses to its plain total and its map is dropped. A declared list would
    /// be a second place to keep the enum's shape, and those disagree.
    private var labelTotals: [MetricEvent: [String: Int]] = [:]
    private var collapsedLabels: Set<MetricEvent> = []
    private let maxLabelsPerEvent = 8

    // Computed latency samples (message receive end-to-end)
    private var latencySamples: [LatencySample] = []
    private let maxSamples = 100

    // Pending start times keyed by label (messageId, userId, etc.)
    private var pendingStarts: [String: (event: MetricEvent, time: CFAbsoluteTime)] = [:]

    // OSSignposter for Instruments integration
    private let signposter = OSSignposter(subsystem: "cc.konstruct.messenger", category: "Performance")

    // MARK: - Recording

    func record(_ event: MetricEvent, label: String = "", value: Double? = nil) {
        let now = CFAbsoluteTimeGetCurrent()
        let record = MetricRecord(timestamp: now, event: event, label: label, value: value)
        lock.lock()
        if events.count >= maxEvents { events.removeFirst() }
        events.append(record)
        totals[event, default: 0] += 1
        if !label.isEmpty, !collapsedLabels.contains(event) {
            var byLabel = labelTotals[event] ?? [:]
            byLabel[label, default: 0] += 1
            if byLabel.count > maxLabelsPerEvent {
                collapsedLabels.insert(event)
                labelTotals[event] = nil
            } else {
                labelTotals[event] = byLabel
            }
        }
        lock.unlock()
    }

    /// Mark start of a paired operation. Call `end(_:label:)` to compute duration.
    func start(_ event: MetricEvent, label: String) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        pendingStarts["\(event.rawValue):\(label)"] = (event, now)
        lock.unlock()
        record(event, label: label)
    }

    /// Cancel a paired operation start without recording an end event.
    /// Used when the operation fails or is superseded (e.g., fast failover).
    func cancelStart(_ event: MetricEvent, label: String) {
        let key = "\(event.rawValue):\(label)"
        lock.lock()
        _ = pendingStarts.removeValue(forKey: key)
        lock.unlock()
    }

    /// Mark end of a paired operation. Returns duration in ms.
    @discardableResult
    func end(_ startEvent: MetricEvent, endEvent: MetricEvent, label: String) -> Double? {
        let now = CFAbsoluteTimeGetCurrent()
        let key = "\(startEvent.rawValue):\(label)"
        lock.lock()
        guard let start = pendingStarts.removeValue(forKey: key) else {
            lock.unlock()
            return nil
        }
        let durationMs = (now - start.time) * 1000
        lock.unlock()

        record(endEvent, label: label, value: durationMs)
        addSample(LatencySample(label: "\(startEvent.rawValue)→\(endEvent.rawValue) \(label)", durationMs: durationMs, timestamp: now))
        return durationMs
    }

    private func addSample(_ sample: LatencySample) {
        lock.lock()
        if latencySamples.count >= maxSamples { latencySamples.removeFirst() }
        latencySamples.append(sample)
        lock.unlock()
    }

    // MARK: - Convenience: message receive pipeline

    func messageEnvelopeArrived(messageId: String) {
        start(.envelopeArrived, label: messageId)
    }

    func messageDecryptStart(messageId: String) {
        start(.decryptStart, label: messageId)
    }

    func messageDecryptEnd(messageId: String) {
        end(.decryptStart, endEvent: .decryptEnd, label: messageId)
    }

    /// Call after message is inserted into CoreData (visible to UI).
    func messageUIDisplayed(messageId: String) {
        let durationMs = end(.envelopeArrived, endEvent: .uiDisplayed, label: messageId)
        if let ms = durationMs {
            let label = String(messageId.prefix(8))
            Log.debug("PERF msg=\(label)… receive→display: \(String(format: "%.1f", ms))ms", category: "Metrics")
        }
    }

    func coreDataSaveStart(label: String) {
        start(.coreDataSaveStart, label: label)
    }

    func coreDataSaveEnd(label: String) {
        end(.coreDataSaveStart, endEvent: .coreDataSaveEnd, label: label)
    }

    func coreDataSaveFailed(label: String) {
        cancelStart(.coreDataSaveStart, label: label)
        record(.coreDataSaveFailed, label: label)
    }

    // MARK: - Queries

    func allEvents() -> [MetricRecord] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func recentSamples(limit: Int = 20) -> [LatencySample] {
        lock.lock()
        defer { lock.unlock() }
        return Array(latencySamples.suffix(limit))
    }

    func averageLatency(for eventPair: String, last n: Int = 20) -> Double? {
        lock.lock()
        let relevant = latencySamples.filter { $0.label.hasPrefix(eventPair) }.suffix(n)
        lock.unlock()
        guard !relevant.isEmpty else { return nil }
        return relevant.map(\.durationMs).reduce(0, +) / Double(relevant.count)
    }

    /// How many times `event` has been recorded since launch, or since the last `clearAll()`.
    ///
    /// Reads the monotonic total, never the ring buffer. The previous implementation counted
    /// matches among the last 200 records of *all* events, so no answer above 200 was reachable
    /// and every answer below it was a function of whatever else happened to be busy. Its one
    /// production caller is the "Token-less sends" row in `DiagnosticsView`, which is the evidence
    /// the Privacy Pass enforce decision turns on (TODO 47).
    ///
    /// The `last n` window it used to take had no caller and is gone rather than renamed: a
    /// parameter that silently truncates is the same defect as the buffer it read from.
    func count(event: MetricEvent) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return totals[event] ?? 0
    }

    /// One line of cumulative per-event totals, or `nil` if nothing has been recorded since the
    /// last call.
    ///
    /// Cumulative rather than per-interval so the *last* such line in a log is the whole run — one
    /// `grep | tail -1` instead of adding up a time series by hand — while the earlier lines still
    /// show when a burst happened. Silent when nothing moved, so a quiet device costs no lines.
    ///
    /// Every event is included, the high-volume pipeline ones too: they are the denominators. A
    /// count of failures with no count of traffic beside it is exactly how
    /// `chunk_reassembly_incomplete` read as eleven losses for a photo that arrived intact
    /// (`ios-semantic-divergence-signals` rule 1a).
    ///
    /// Events whose label is a closed set carry it: `token_wallet_wait=104(served=71,timeout=28,
    /// backoff=5)`. That breakdown *is* the gauge — the bare total answers nothing the enforce
    /// decision asks. Events labelled with an identifier collapse to the total; see `labelTotals`.
    func changedSignalsSummary() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard totals != reportedTotals else { return nil }
        reportedTotals = totals
        return totals
            .sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key.rawValue < rhs.key.rawValue : lhs.value > rhs.value
            }
            .map { event, total in
                guard let byLabel = labelTotals[event], !byLabel.isEmpty else {
                    return "\(event.rawValue)=\(total)"
                }
                let breakdown = byLabel
                    .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: ",")
                return "\(event.rawValue)=\(total)(\(breakdown))"
            }
            .joined(separator: " ")
    }

    func p95Latency(for eventPair: String, last n: Int = 20) -> Double? {
        lock.lock()
        let relevant = latencySamples.filter { $0.label.hasPrefix(eventPair) }.suffix(n)
        lock.unlock()
        guard !relevant.isEmpty else { return nil }
        let sorted = relevant.map(\.durationMs).sorted()
        let idx = max(0, Int(Double(sorted.count) * 0.95) - 1)
        return sorted[idx]
    }

    func clearAll() {
        lock.lock()
        events.removeAll()
        latencySamples.removeAll()
        pendingStarts.removeAll()
        totals.removeAll()
        reportedTotals.removeAll()
        labelTotals.removeAll()
        collapsedLabels.removeAll()
        lock.unlock()
    }
}

// MARK: - OSSignposter integration

extension PerformanceMetrics {

    private static let spLog = OSLog(subsystem: "cc.konstruct.messenger", category: .pointsOfInterest)

    static func signpostBegin(_ name: StaticString, id: OSSignpostID = .exclusive) {
        os_signpost(.begin, log: spLog, name: name)
    }

    static func signpostEnd(_ name: StaticString) {
        os_signpost(.end, log: spLog, name: name)
    }

    static func signpostEvent(_ name: StaticString, format: StaticString = "", _ args: CVarArg...) {
        os_signpost(.event, log: spLog, name: name)
    }
}

#else

// MARK: - Release stubs (compile-out)

final class PerformanceMetrics: @unchecked Sendable {
    static let shared = PerformanceMetrics()
    private init() {}

    @inline(__always) func record(_ event: MetricEvent, label: String = "", value: Double? = nil) {}
    @inline(__always) func start(_ event: MetricEvent, label: String) {}
    @inline(__always) func cancelStart(_ event: MetricEvent, label: String) {}
    @discardableResult @inline(__always) func end(_ startEvent: MetricEvent, endEvent: MetricEvent, label: String) -> Double? { nil }
    @inline(__always) func messageEnvelopeArrived(messageId: String) {}
    @inline(__always) func messageDecryptStart(messageId: String) {}
    @inline(__always) func messageDecryptEnd(messageId: String) {}
    @inline(__always) func messageUIDisplayed(messageId: String) {}
    @inline(__always) func coreDataSaveStart(label: String) {}
    @inline(__always) func coreDataSaveEnd(label: String) {}
    @inline(__always) func coreDataSaveFailed(label: String) {}
    @inline(__always) func clearAll() {}
    @inline(__always) func count(event: MetricEvent) -> Int { 0 }
    @inline(__always) func changedSignalsSummary() -> String? { nil }
}

#endif
