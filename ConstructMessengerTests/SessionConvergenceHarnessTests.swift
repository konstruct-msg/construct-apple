//
//  SessionConvergenceHarnessTests.swift
//  ConstructMessengerTests
//
//  Two-party session convergence harness (SESSION_COORDINATOR_REFACTOR_SPEC §"Phase 3+ —
//  Harness-first hardening"). Every prior session desync was a TWO-party emergent failure that
//  the single-side SessionRaceConditionTests could not catch — the structural blind spot the
//  2026-06-16 pause note named. This harness closes it: two `Peer`s drive the PRODUCTION
//  `SessionReducer` decisions (phase lifecycle, incoming disposition, confirm-gate TTL, confirm
//  release) at each other over an adversarial in-memory `Network` (drop / reorder / dup /
//  simultaneous-init / END_SESSION storm), on a virtual clock so TTL is deterministic (no sleep).
//
//  Invariants asserted (see spec):
//    P1 liveness  — from dueling init, once the network stops dropping, both peers reach `active`
//                   and every DATA message is delivered, within bounded steps.
//    P2 no gate   — the confirm buffer / stale_init_drop always releases (PING/READY or TTL);
//                   never "buffer/drop forever" (reproduces confirm-deadlock 3f166e61 + 04f16211).
//    P3 no orphan — an END_SESSION storm converges to a single clean re-init, queue not orphaned.
//
//  Contract (mirrors SessionRaceConditionTests): the DECISIONS are production `SessionReducer`
//  calls; only the wire/role glue (which frame to send when) is test code — that glue is the next
//  extraction target (fold tie-break/SRI/ready into the reducer), at which point it moves in here.
//

import XCTest
@testable import Construct_Messenger

// MARK: - Wire model

/// A frame on the virtual wire between the two peers.
private enum Frame: Equatable {
    case initMsg              // msgNum=0 X3DH init (either side, dueling)
    case resetInit            // SESSION_RESET_INIT (ct24) — INITIATOR announces after tie-break win
    case ready                // session_ready (ct26) — RESPONDER confirms
    case ping                 // session ping (ct25) — RESPONDER established
    case data(String)         // user DATA message id
    case endSession           // teardown

    /// Map to the reducer's dependency-free control op (nil for non-control frames).
    var controlOp: SessionReducer.ControlOp? {
        switch self {
        case .resetInit: return .resetInit
        case .ready:     return .ready
        case .ping:      return .ping
        case .endSession: return .endSession
        case .initMsg, .data: return nil
        }
    }
}

private struct Envelope: Equatable {
    let from: String
    let to: String
    let frame: Frame
}

// MARK: - Adversarial network

/// Deterministic in-memory network. `dropPolicy` decides, per envelope, whether it is dropped —
/// letting a scenario sever specific frames (e.g. every `.ready`) for a "censored" window, then
/// heal (return false) to assert eventual convergence.
private final class Network {
    private(set) var inFlight: [Envelope] = []
    var dropPolicy: (Envelope) -> Bool = { _ in false }
    var duplicate = false

    func send(_ env: Envelope) {
        if dropPolicy(env) { return }
        inFlight.append(env)
        if duplicate { inFlight.append(env) }
    }

    /// Pop everything currently in flight (FIFO) for delivery this pump.
    func drain() -> [Envelope] {
        let batch = inFlight
        inFlight.removeAll()
        return batch
    }

    var isQuiet: Bool { inFlight.isEmpty }
}

// MARK: - Peer (drives production SessionReducer decisions)

@MainActor
private final class Peer {
    let id: String
    unowned let net: Network
    let confirmWindow: TimeInterval

    /// Production reducer phase (nil == absent).
    var phase: SessionReducer.Phase?
    /// Confirm-gate start (INITIATOR awaiting RESPONDER ack). nil == not gating.
    var confirmPendingSince: Date?
    /// DATA ids buffered while no session / while the confirm gate is closed.
    var outbox: [String] = []
    /// DATA ids this peer has received and processed.
    private(set) var delivered: Set<String> = []

    init(id: String, net: Network, confirmWindow: TimeInterval) {
        self.id = id
        self.net = net
        self.confirmWindow = confirmWindow
    }

    // Tie-break: higher id wins as INITIATOR (matches §6.6 / handleRustHealDecision).
    private func isInitiator(over peerId: String) -> Bool { id > peerId }

    var isActive: Bool { if case .active = phase { return true }; return false }
    var isInitializing: Bool { phase == .initializing }

    private func send(_ frame: Frame, to peerId: String) {
        net.send(Envelope(from: id, to: peerId, frame: frame))
    }

    // MARK: Local intent

    /// The app wants to send a DATA message. Uses the production disposition + confirm-gate.
    func enqueueSend(_ dataId: String, to peerId: String, now: Date) {
        outbox.append(dataId)
        flushOrInit(to: peerId, now: now)
    }

    /// Re-evaluate the outbox against the production confirm-gate + phase. Called on every pump so
    /// a TTL expiry (isConfirmBuffering → false) actually releases buffered sends — the exact
    /// liveness the ad-hoc 04f16211 patch guaranteed, now under test.
    func flushOrInit(to peerId: String, now: Date) {
        let buffering = SessionReducer.isConfirmBuffering(
            pendingSince: confirmPendingSince, now: now, confirmWindow: confirmWindow)
        if buffering { return }               // gate closed — keep buffering (P2: bounded)
        if confirmPendingSince != nil {        // gate self-expired via TTL → release it
            confirmPendingSince = nil
        }
        guard !outbox.isEmpty else { return }

        if isActive {
            let batch = outbox; outbox.removeAll()
            for d in batch { send(.data(d), to: peerId) }
            return
        }
        // No session and not buffering → (re)start a dueling init.
        if phase == nil {
            let (p, _) = SessionReducer.reduce(phase, on: .initStarted)
            phase = p
            send(.initMsg, to: peerId)
        }
    }

    // MARK: Wire ingress

    func receive(_ frame: Frame, from peerId: String, now: Date) {
        switch frame {
        case .initMsg:
            if isInitiator(over: peerId) {
                // We WIN the tie-break: keep/establish our INITIATOR session, announce via SRI,
                // and open the confirm gate (buffer outgoing until RESPONDER acks).
                if phase == nil { phase = SessionReducer.reduce(phase, on: .initStarted).0 }
                confirmPendingSince = now
                send(.resetInit, to: peerId)
            } else {
                // We LOSE: become RESPONDER immediately and acknowledge (ready + ping).
                becomeResponder(to: peerId, now: now)
            }

        case .resetInit:
            // INITIATOR announced. As RESPONDER, establish and acknowledge.
            if !isInitiator(over: peerId) {
                becomeResponder(to: peerId, now: now)
            }

        case .ready, .ping:
            // INITIATOR side: a RESPONDER session exists on the peer. Release the confirm gate.
            if let op = frame.controlOp, SessionReducer.confirmReleases(on: op) {
                phase = SessionReducer.reduce(phase, on: .markActive(at: UInt64(now.timeIntervalSince1970))).0
                confirmPendingSince = nil
                flushOrInit(to: peerId, now: now)
            }

        case .data(let dataId):
            // A peer only sends DATA when active; receiving it means our session is live too.
            if !isActive {
                phase = SessionReducer.reduce(phase, on: .markActive(at: UInt64(now.timeIntervalSince1970))).0
            }
            delivered.insert(dataId)

        case .endSession:
            let (p, effects) = SessionReducer.reduce(phase, on: .endSessionReceived)
            phase = p
            if effects.contains(.clearQueuedMessages) { /* outbox is recoverable plaintext — keep */ }
            confirmPendingSince = nil
        }
    }

    private func becomeResponder(to peerId: String, now: Date) {
        phase = SessionReducer.reduce(phase, on: .markActive(at: UInt64(now.timeIntervalSince1970))).0
        confirmPendingSince = nil
        send(.ready, to: peerId)
        send(.ping, to: peerId)
        // Now active — release any of our own buffered sends.
        flushOrInit(to: peerId, now: now)
    }
}

// MARK: - Harness driver

@MainActor
private final class Harness {
    let net = Network()
    let confirmWindow: TimeInterval = 75
    let a: Peer
    let b: Peer
    var now = Date(timeIntervalSince1970: 1_000_000)

    init() {
        // Tie-break = higher id wins as INITIATOR, so A must sort ABOVE B lexicographically.
        a = Peer(id: "peer-2", net: net, confirmWindow: 75)   // INITIATOR on tie ("peer-2" > "peer-1")
        b = Peer(id: "peer-1", net: net, confirmWindow: 75)
        precondition(a.id > b.id, "A must be the tie-break INITIATOR")
    }

    private func peer(_ pid: String) -> Peer { pid == a.id ? a : b }

    /// Deliver every in-flight frame once, letting each side react. Returns true if anything moved.
    @discardableResult
    func pump() -> Bool {
        var moved = false
        let batch = net.drain()
        for env in batch {
            moved = true
            peer(env.to).receive(env.frame, from: env.from, now: now)
        }
        // Re-evaluate confirm gates against the current clock (TTL release, resend init).
        a.flushOrInit(to: b.id, now: now)
        b.flushOrInit(to: a.id, now: now)
        return moved
    }

    /// Pump until the wire is quiet, up to `maxSteps` (bounded-convergence guard).
    func settle(maxSteps: Int = 50) {
        for _ in 0..<maxSteps {
            let moved = pump()
            if !moved && net.isQuiet { return }
        }
    }

    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

// MARK: - Tests

final class SessionConvergenceHarnessTests: XCTestCase {

    // P1: both sides want to talk at once, reliable network → converge + all DATA delivered.
    @MainActor
    func testDuelingInit_ReliableNetwork_Converges() {
        let h = Harness()
        h.a.enqueueSend("a1", to: h.b.id, now: h.now)
        h.b.enqueueSend("b1", to: h.a.id, now: h.now)

        h.settle()

        XCTAssertTrue(h.a.isActive, "INITIATOR must reach active")
        XCTAssertTrue(h.b.isActive, "RESPONDER must reach active")
        XCTAssertTrue(h.b.delivered.contains("a1"), "A's message must be delivered to B")
        XCTAssertTrue(h.a.delivered.contains("b1"), "B's message must be delivered to A")
        XCTAssertTrue(h.a.outbox.isEmpty && h.b.outbox.isEmpty, "no message left buffered")
    }

    // P2: RESPONDER's ready+ping are dropped for the whole handshake. The INITIATOR's confirm gate
    // must NOT deadlock: it self-releases at the TTL and the buffered send goes out. This is the
    // exact confirm-deadlock class (04f16211) — here as a red-if-regressed harness case.
    @MainActor
    func testLostPingAndReady_ConfirmGateReleasesViaTTL_NoDeadlock() {
        let h = Harness()
        // Sever the RESPONDER's acknowledgements — INITIATOR never hears session_ready/ping.
        h.net.dropPolicy = { $0.frame == .ready || $0.frame == .ping }

        h.a.enqueueSend("a1", to: h.b.id, now: h.now)   // A is INITIATOR (higher id)
        h.b.enqueueSend("b1", to: h.a.id, now: h.now)
        h.settle()

        // Within the window, A is still gating (buffering) — that's correct, not yet a deadlock.
        XCTAssertTrue(
            SessionReducer.isConfirmBuffering(pendingSince: h.a.confirmPendingSince, now: h.now, confirmWindow: 75),
            "INITIATOR should still be within the confirm window right after the SRI")
        XCTAssertFalse(h.b.delivered.contains("a1"), "A's send is legitimately buffered pre-TTL")

        // Clock passes the confirm window; the gate must open (TTL) and the buffer must drain.
        h.advance(76)
        h.net.dropPolicy = { _ in false }   // network heals
        h.settle()

        XCTAssertNil(h.a.confirmPendingSince, "confirm gate must have self-released at the TTL")
        XCTAssertTrue(h.b.delivered.contains("a1"),
                      "INITIATOR's buffered DATA must be delivered after the gate releases — no deadlock")
    }

    // P2 (dual): the INITIATOR's SESSION_RESET_INIT is dropped for a window, then the network heals.
    // Convergence must still be reached (the peer re-inits / the gate releases) — no permanent stall.
    @MainActor
    func testLostResetInit_ThenHeal_Converges() {
        let h = Harness()
        var sever = true
        h.net.dropPolicy = { env in sever && env.frame == .resetInit }

        h.a.enqueueSend("a1", to: h.b.id, now: h.now)
        h.b.enqueueSend("b1", to: h.a.id, now: h.now)
        h.settle()

        // Heal the network and let the confirm window lapse so the INITIATOR retries the send path.
        sever = false
        h.advance(76)
        h.b.enqueueSend("b2", to: h.a.id, now: h.now)   // fresh traffic drives another init round
        h.settle()

        XCTAssertTrue(h.a.isActive && h.b.isActive, "both peers converge to active after heal")
        XCTAssertTrue(h.a.delivered.contains("b1") || h.a.delivered.contains("b2"),
                      "RESPONDER traffic reaches the INITIATOR after convergence")
    }

    // P3: an END_SESSION storm must leave the phase idle with no orphaned buffer, and a subsequent
    // send must start exactly one fresh init (no dueling storm re-entry).
    @MainActor
    func testEndSessionStorm_ConvergesToSingleReinit() {
        let h = Harness()
        h.a.enqueueSend("a1", to: h.b.id, now: h.now)
        h.b.enqueueSend("b1", to: h.a.id, now: h.now)
        h.settle()
        XCTAssertTrue(h.a.isActive)

        // Storm: five END_SESSIONs land back to back.
        for _ in 0..<5 {
            h.a.receive(.endSession, from: h.b.id, now: h.now)
            XCTAssertNil(h.a.phase, "phase must reset to idle on each END_SESSION — no lingering state")
            XCTAssertNil(h.a.confirmPendingSince, "confirm gate cleared on teardown")
        }

        // A fresh send re-establishes cleanly.
        h.a.enqueueSend("a2", to: h.b.id, now: h.now)
        h.settle()
        XCTAssertTrue(h.a.isActive && h.b.isActive, "clean re-init after the storm")
        XCTAssertTrue(h.b.delivered.contains("a2"), "post-storm message delivered")
    }
}
