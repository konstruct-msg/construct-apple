//
//  TransportRouteConformanceTests.swift
//  ConstructMessengerTests
//
//  `TransportReducer.route` against construct-protos `conformance/transport_route.json`, vendored
//  into `Networking/gRPC/Generated/conformance/`. Android runs the same file against
//  `TransportRoute.kt`. Routing is not protocol, so each platform keeps its own machine; the file
//  is what keeps them from drifting apart unnoticed.
//  Decision: construct-docs decisions/transport-route-per-platform-shared-vectors.md.
//

import XCTest
@testable import Construct_Messenger

final class TransportRouteConformanceTests: XCTestCase {

    private var doc: [String: Any] = [:]
    private var nowMs: Int64 = 0
    private var veil: TransportTarget = .direct(.h2)

    override func setUpWithError() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConstructMessenger/Networking/gRPC/Generated/conformance/transport_route.json")
        doc = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        nowMs = try XCTUnwrap(doc["now_ms"] as? NSNumber).int64Value
        let target = try XCTUnwrap(doc["veil_target"] as? [String: Any])
        veil = .veil(port: UInt16(try XCTUnwrap(target["port"] as? Int)), relay: try XCTUnwrap(target["relay"] as? String))
    }

    /// Mutation: drop the Auto de-escalation from `route` — `auto_leaves_veil_when_direct_answers`
    /// reddens; allow escalation under Off — both `off_never_escalates*` redden.
    func testEveryCaseEndsWhereTheVectorsSay() throws {
        let cases = try XCTUnwrap(doc["cases"] as? [[String: Any]])
        // An empty file would make the loop vacuous.
        XCTAssertGreaterThan(cases.count, 40, "vectors look truncated")
        let now = date(nowMs)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            if let initial = c["initial"] as? [String: Any] {
                let state = TransportState.initial(
                    mode: try mode(initial["mode"]),
                    censored: initial["censored"] as? Bool ?? false,
                    reachable: initial["reachable"] as? Bool ?? true
                )
                XCTAssertEqual(state, try self.state(c["expect_state"]), name)
                continue
            }
            let mode = try mode(c["mode"])
            currentMode = mode
            let config = config(c["config"] as? [String: Any])
            var state = try self.state(c["state"])
            var effects: [TransportEffect] = []
            for e in try XCTUnwrap(c["events"] as? [[String: Any]]) {
                let outcome = TransportReducer.route(state: state, event: try event(e), mode: mode, config: config, now: now)
                state = outcome.state
                effects = outcome.effects
            }
            XCTAssertEqual(state, try self.state(c["expect_state"]), "\(name): state")
            XCTAssertEqual(effects, try self.effects(c["expect_effects"]), "\(name): effects")
        }
    }

    func testTheDefaultConfigIsTheVectorsDefault() throws {
        let d = try XCTUnwrap(doc["default_config"] as? [String: Any])
        let c = TransportConfig.default
        XCTAssertEqual(c.directFailThreshold, d["direct_fail_threshold"] as? Int)
        XCTAssertEqual(c.midSessionDeathWeight, d["mid_session_death_weight"] as? Int)
        XCTAssertEqual(c.allowDirectToVeilEscalation, d["allow_direct_to_veil_escalation"] as? Bool)
        XCTAssertEqual(Int64(c.veilCooldownDuration * 1000), (d["veil_cooldown_ms"] as? NSNumber)?.int64Value)
    }

    // MARK: - Decoding

    private struct Unknown: Error { let what: String }

    private func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(ms) / 1000) }

    private func mode(_ any: Any?) throws -> VeilMode {
        guard let s = any as? String, let m = VeilMode(rawValue: s) else { throw Unknown(what: "mode \(String(describing: any))") }
        return m
    }

    private func config(_ o: [String: Any]?) -> TransportConfig {
        var c = TransportConfig.default
        guard let o else { return c }
        if let v = o["direct_fail_threshold"] as? Int { c.directFailThreshold = v }
        if let v = o["mid_session_death_weight"] as? Int { c.midSessionDeathWeight = v }
        if let v = o["allow_direct_to_veil_escalation"] as? Bool { c.allowDirectToVeilEscalation = v }
        if let v = o["veil_cooldown_ms"] as? NSNumber { c.veilCooldownDuration = TimeInterval(v.int64Value) / 1000 }
        return c
    }

    private func target(_ any: Any?) -> TransportTarget { (any as? String) == "veil" ? veil : .direct(.h2) }

    private func int64(_ any: Any?) -> Int64 { (any as? NSNumber)?.int64Value ?? 0 }

    private func state(_ any: Any?) throws -> TransportState {
        let o = any as? [String: Any] ?? [:]
        switch o["kind"] as? String {
        case "offline": return .offline
        case "direct": return .direct(consecutiveFails: o["fails"] as? Int ?? -1)
        case "veil_probing": return .veilProbing
        case "veil_active":
            return .veilActive(relay: o["relay"] as? String ?? "", port: UInt16(o["port"] as? Int ?? 0), since: date(int64(o["since_ms"])))
        case "veil_cooldown": return .veilCooldown(until: date(int64(o["until_ms"])))
        default: throw Unknown(what: "state \(o)")
        }
    }

    private func streamMethod(_ any: Any?) throws -> StreamMethod {
        switch any as? String {
        case "quic": return .quic
        case "h2": return .h2
        case "veil": return .veil
        default: throw Unknown(what: "method \(String(describing: any))")
        }
    }

    private func streamFailure(_ any: Any?) throws -> StreamFailureKind {
        switch any as? String {
        case "open_timeout": return .openTimeout
        case "mid_session_timeout": return .midSessionTimeout
        case "write_failed": return .writeFailed
        case "closed": return .closed
        case "transport_unknown": return .transportUnknown
        case "mid_session_closed": return .midSessionClosed
        case "mid_session_unknown": return .midSessionUnknown
        default: throw Unknown(what: "stream failure \(String(describing: any))")
        }
    }

    private func rpcFailure(_ any: Any?) throws -> RPCFailureKind {
        switch any as? String {
        case "transient_cancellation": return .transientCancellation
        case "auth_rejected": return .authRejected
        case "application_error": return .applicationError
        case "tls_fingerprint_blocked": return .tlsFingerprintBlocked
        case "tls_cert_expired": return .tlsCertExpired
        case "web_tunnel_blocked": return .webTunnelBlocked
        case "stale_local_proxy": return .staleLocalProxy
        case "stream_timeout": return .streamTimeout
        case "transport_unknown": return .transportUnknown
        default: throw Unknown(what: "rpc failure \(String(describing: any))")
        }
    }

    private func event(_ o: [String: Any]) throws -> TransportEvent {
        switch o["kind"] as? String {
        case "rpc_succeeded": return .rpcSucceeded(via: target(o["via"]), latencyMs: o["latency_ms"] as? Int ?? 0)
        case "rpc_failed":
            return .rpcFailed(kind: try rpcFailure(o["failure"]), via: target(o["via"]), foreground: o["foreground"] as? Bool ?? true)
        case "stream_opened": return .streamOpened(method: try streamMethod(o["method"]), via: target(o["via"]))
        case "stream_failed":
            return .streamFailed(method: try streamMethod(o["method"]), kind: try streamFailure(o["failure"]), via: target(o["via"]))
        case "network_path_changed":
            // The mode rides on the event on iOS; `route` is handed the case's mode separately, and
            // the reducer reads the event's copy — the two are the same here by construction.
            return .networkPathChanged(reachable: o["reachable"] as? Bool ?? true, censored: o["censored"] as? Bool ?? false, mode: currentMode)
        case "veil_mode_changed": return .veilModeChanged(currentMode, censored: o["censored"] as? Bool ?? false)
        case "veil_config_changed": return .veilConfigChanged
        case "background_wake": return .backgroundWake
        case "proxy_started":
            return .proxyStarted(relay: o["relay"] as? String ?? "", port: UInt16(o["port"] as? Int ?? 0), restarted: o["restarted"] as? Bool ?? false)
        case "proxy_start_failed": return .proxyStartFailed(relay: o["relay"] as? String, reason: o["reason"] as? String ?? "")
        case "cooldown_elapsed": return .cooldownElapsed
        case "manual_reset": return .manualReset
        default: throw Unknown(what: "event \(o)")
        }
    }

    private func effects(_ any: Any?) throws -> [TransportEffect] {
        try (any as? [[String: Any]] ?? []).map { o in
            switch o["kind"] as? String {
            case "invalidate_grpc_client": return .invalidateGRPCClient
            case "set_veil_port": return .setVeilPort((o["port"] as? Int).map { UInt16($0) })
            case "request_proxy_start": return .requestProxyStart
            case "request_proxy_stop": return .requestProxyStop
            case "schedule_cooldown_end": return .scheduleCooldownEnd(at: date(int64(o["at_ms"])))
            default: throw Unknown(what: "effect \(o)")
            }
        }
    }

    /// Set per case before its events are decoded; see `event`.
    private var currentMode: VeilMode = .auto
}
