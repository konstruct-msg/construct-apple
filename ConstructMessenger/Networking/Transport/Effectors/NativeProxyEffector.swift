//
//  NativeProxyEffector.swift
//  Construct Messenger
//
//  Concrete `ProxyEffector` that owns an `VeilProxy` actor and a `RelayPool` to
//  pick the next relay candidate. This is the bridge between the FSM and the
//  Rust VEIL proxy lifecycle.
//
//  Selection logic here is intentionally minimal — `RelayPool.best()` is the
//  same call ConnectionLoop used. Chunk 5 will replace this with a geo-aware
//  RelaySelector; the FSM remains unchanged.
//

import Foundation

actor NativeProxyEffector: ProxyEffector {
    private let proxy: VeilProxy
    private var pool: RelayPool

    init(initialRelays: [VeilRelay], blockedPenalty: [String: Int]) {
        self.proxy = VeilProxy()
        self.pool = RelayPool(relays: initialRelays, blockedPenalty: blockedPenalty)
    }

    func start() async -> TransportEvent {
        guard !pool.isEmpty else {
            return .proxyStartFailed(relay: nil, reason: "relay pool empty")
        }
        guard let relay = pool.best() else {
            return .proxyStartFailed(relay: nil, reason: "no usable relay")
        }
        // Last gate before `veil_start`. If this device learned a pin for the address, the
        // relay handed to the proxy must carry that exact pin — anything else means the
        // pin was lost or overwritten somewhere in the build path, and dialing a vouched
        // front unpinned would hand its traffic to whoever answers on that address.
        // Fail loudly and let the pool rotate rather than connect.
        if let learnedPin = VeilLearnedFrontStore.shared.pin(for: relay.address),
           (relay.pinnedSpki ?? "").lowercased() != learnedPin {
            pool.recordFailure(relay)
            return .proxyStartFailed(relay: relay.address, reason: "learned front offered without its pin")
        }
        do {
            let result = try await proxy.ensure(relay: relay)
            await VeilProxyManager.shared.reportLastError(nil)
            return .proxyStarted(relay: relay.address, port: result.port, restarted: result.restarted)
        } catch {
            pool.recordFailure(relay)
            // Prefer the clean, real reason (veil_last_error → VeilProxyRuntimeError)
            // over the raw nested enum description.
            let reason = (error as? VeilProxyError)?.localizedDescription ?? "\(error)"
            await VeilProxyManager.shared.reportLastError(reason)
            return .proxyStartFailed(relay: relay.address, reason: reason)
        }
    }

    func stop() async {
        await proxy.stop()
    }

    func updateRelays(_ relays: [VeilRelay]) async {
        // Preserve any persistent penalties carried by the existing pool.
        pool = RelayPool(relays: relays, blockedPenalty: pool.blockedPenalty)
    }
}
