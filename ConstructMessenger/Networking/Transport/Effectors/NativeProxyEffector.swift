//
//  NativeProxyEffector.swift
//  Construct Messenger
//
//  Concrete `ProxyEffector` that owns an `VeilProxy` actor and a `RelayPool` to
//  pick the next relay candidate. This is the bridge between the FSM and the
//  Rust VEIL proxy lifecycle.
//
//  Selection logic here is intentionally minimal — `RelayPool.best()`. A geo-aware
//  selector is deferred; the FSM would remain unchanged.
//

import Foundation

actor NativeProxyEffector: ProxyEffector {
    private let proxy: VeilProxy
    private var pool: RelayPool
    /// Brings the proxy up on one relay — `proxy.ensure`, or a test's stand-in.
    private let ensure: @Sendable (VeilRelay) async throws -> VeilProxyEnsureResult
    /// Tells `VeilProxyManager` about failures and errors; off in a test, where that would start
    /// the front-floor maintainer on made-up addresses.
    private let reportsToManager: Bool

    init(initialRelays: [VeilRelay], blockedPenalty: [String: Int]) {
        let proxy = VeilProxy()
        self.proxy = proxy
        self.pool = RelayPool(relays: initialRelays, blockedPenalty: blockedPenalty)
        self.ensure = { try await proxy.ensure(relay: $0) }
        self.reportsToManager = true
    }

    #if DEBUG
    init(initialRelays: [VeilRelay], ensure: @escaping @Sendable (VeilRelay) async throws -> VeilProxyEnsureResult) {
        self.proxy = VeilProxy()
        self.pool = RelayPool(relays: initialRelays)
        self.ensure = ensure
        self.reportsToManager = false
    }
    #endif

    /// Whether the port the proxy gave us is still held. Not `veil_is_alive`: it misses a port
    /// iOS reclaimed during a suspend, and on the native-TLS path — where Swift, not the Rust
    /// coordinator, owns the listener — it says "no" while the port works, which restarted a
    /// healthy proxy on every return to the foreground (2026-10-02). Not a connect either: that
    /// opens a tunnel. `LocalListenerProbe` binds the port instead.
    func listenerIsAlive() async -> Bool {
        guard let port = await proxy.port else { return false }
        return LocalListenerProbe.isHeld(port: port)
    }

    /// Bring the proxy up on the best relay, and on a failure try the next one at once — each
    /// relay once per call. Only when every one has failed does the router see a failure and
    /// cool down: on 2026-10-14 a phone sat out a 29 s cooldown after its first front failed,
    /// with three working fronts configured beside it.
    func start() async -> TransportEvent {
        guard !pool.isEmpty else {
            return .proxyStartFailed(relay: nil, reason: "relay pool empty")
        }
        var tried = Set<String>()
        var last: TransportEvent = .proxyStartFailed(relay: nil, reason: "no usable relay")
        while let relay = pool.best(notIn: tried) {
            tried.insert(relay.address)
            guard let outcome = await start(relay) else {
                // Stopped on purpose, not the relay's fault: no failure counted, no next relay.
                return .proxyStartFailed(relay: relay.address, reason: VeilProxyError.stopped.localizedDescription)
            }
            last = outcome
            if case .proxyStarted = last { return last }
        }
        return last
    }

    /// nil when the proxy was stopped while this start dialed.
    private func start(_ relay: VeilRelay) async -> TransportEvent? {
        // Last gate before `veil_start`. If this device learned a pin for the address, the
        // relay handed to the proxy must carry that exact pin — anything else means the
        // pin was lost or overwritten somewhere in the build path, and dialing a vouched
        // front unpinned would hand its traffic to whoever answers on that address.
        // Fail loudly and let the pool rotate rather than connect.
        if let learnedPin = VeilLearnedFrontStore.shared.pin(for: relay.address),
           (relay.pinnedSpki ?? "").lowercased() != learnedPin {
            pool.recordFailure(relay)
            if reportsToManager { await VeilProxyManager.shared.handleRelayUnavailable(relay.address) }
            return .proxyStartFailed(relay: relay.address, reason: "learned front offered without its pin")
        }
        do {
            let result = try await ensure(relay)
            // Up again: forgive it, as Android does. A front demoted by a rotation stays behind
            // the others until it is next chosen and comes up.
            pool.recordSuccess(relay)
            if reportsToManager { await VeilProxyManager.shared.reportLastError(nil) }
            return .proxyStarted(relay: relay.address, port: result.port, restarted: result.restarted)
        } catch VeilProxyError.stopped {
            return nil
        } catch {
            pool.recordFailure(relay)
            if reportsToManager { await VeilProxyManager.shared.handleRelayUnavailable(relay.address) }
            // Prefer the clean, real reason (veil_last_error → VeilProxyRuntimeError)
            // over the raw nested enum description.
            let reason = (error as? VeilProxyError)?.localizedDescription ?? "\(error)"
            if reportsToManager { await VeilProxyManager.shared.reportLastError(reason) }
            Log.info("VEIL: \(relay.address) failed — \(reason)", category: "VEIL")
            return .proxyStartFailed(relay: relay.address, reason: reason)
        }
    }

    func stop() async {
        await proxy.stop()
    }

    func demote(relay address: String) async {
        pool.recordFailure(address: address)
        Log.info("VEIL: \(address) demoted — the rotation blames it", category: "VEIL")
    }

    func updateRelays(_ relays: [VeilRelay]) async {
        // Penalties and failure counts both carry over for the relays still listed. The counts
        // did not until 2026-10-14: the pool is rebuilt on every VEIL enable, every change in
        // local discovery and every voucher, and each rebuild put a front this network cannot
        // reach back at the head of the list — one phone retried it for 16 minutes with three
        // working fronts configured beside it.
        pool = RelayPool(relays: relays, blockedPenalty: pool.blockedPenalty, failures: pool.failureCounts)
    }

    #if DEBUG
    func recordFailureForTesting(address: String) { pool.recordFailure(address: address) }
    func bestForTesting() -> String? { pool.best()?.address }
    #endif
}
