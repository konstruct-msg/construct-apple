//
//  VeilLocalDiscovery.swift
//  Construct Messenger
//
//  EntryDirectory Source 3 — local (mDNS/LAN) discovery of domestic island relays.
//  See construct-docs/decisions/entry-directory-source3-local-discovery.md.
//
//  Load-bearing invariant: **discovery gives reachability, never trust.** Anyone on the
//  LAN (including the adversary) can advertise a `_construct-veil._tcp` service, so a
//  discovered relay is accepted ONLY when its advertised SPKI matches an already-trusted
//  identity — a seed pin (`VEILConfig.seedRelays`) or a pin in the cached Ed25519-signed
//  relay manifest. On a match the discovered LAN address inherits that identity's trust
//  and becomes a new reachability path; on no match it is ignored. This preserves the
//  Option-C anti-redirection invariant: local discovery cannot introduce a new trusted
//  relay, only locate one we already trust. The gate is keyed by SPKI *identity*, not
//  address (the LAN address is new by definition).
//
//  Regime-gated: browsing triggers the iOS local-network permission prompt and costs
//  battery, so this is OFF by default (`start()` is a no-op until called) and is meant to
//  be driven by the censored/island detector — never at launch.
//

import Foundation
import Network

/// A relay learned from the local network, already trust-gated (its `spki` matched a
/// trusted identity). Coordinates only — a working tunnel still needs a per-user
/// capability (same rule as the bundled seed pool).
struct DiscoveredRelay: Equatable {
    let host: String
    let port: Int
    let sni: String?
    /// hex SHA-256 SPKI pin — matched a trusted identity at accept time.
    let spki: String
    /// WebTunnel WebSocket resource path (advert `wt`), or nil for a plain-TLS relay.
    let wtPath: String?

    var addressWithPort: String { "\(host):\(port)" }
}

@MainActor
final class VeilLocalDiscovery {
    static let shared = VeilLocalDiscovery()

    /// Bonjour service type the island relay advertises. Must also be listed in
    /// `Info.plist` `NSBonjourServices` for the browse to be permitted.
    static let serviceType = "_construct-veil._tcp"

    private var browser: NWBrowser?
    private var connections: [NWConnection] = []
    private(set) var discovered: [DiscoveredRelay] = []

    /// Fired after the discovered set changes (and the nonisolated `DiscoveredRelayStore`
    /// snapshot has been refreshed), so the transport layer can re-snapshot its relay pool.
    /// Set by `VeilProxyManager`; nil until then.
    var onDiscoveredRelaysChanged: (() -> Void)?

    private init() {}

    // MARK: - Trust core (pure, unit-tested; nonisolated so the browse callback can gate)

    /// The set of SPKI pins we trust as relay identities: bundled seed pins ∪ the pins in
    /// the cached signed manifest. Lowercased hex for case-insensitive comparison.
    nonisolated static func trustedSPKIs() -> Set<String> {
        var set = Set(VEILConfig.seedRelays.map { $0.spki.lowercased() })
        for info in VeilCertFetcher.cachedRelayInfosSync() ?? [] {
            let s = info.spkiSha256.lowercased()
            if !s.isEmpty { set.insert(s) }
        }
        set.remove("")
        return set
    }

    /// Parse a Bonjour TXT advert into `{spki, sni, wt, version}`. Returns nil if the
    /// required `spki` field is missing/empty. `wt` is the WebTunnel resource path
    /// (present for TLS-WebSocket island relays; absent for plain-TLS).
    nonisolated static func parseAdvert(_ txt: [String: String]) -> (spki: String, sni: String?, wtPath: String?, version: Int)? {
        guard let spki = txt["spki"], !spki.isEmpty else { return nil }
        let sni = txt["sni"].flatMap { $0.isEmpty ? nil : $0 }
        let wtPath = txt["wt"].flatMap { $0.isEmpty ? nil : $0 }
        let version = txt["v"].flatMap { Int($0) } ?? 1
        return (spki, sni, wtPath, version)
    }

    /// The trust gate: accept an advertised SPKI iff it matches a trusted identity.
    nonisolated static func accept(spki: String, trusted: Set<String>) -> Bool {
        !spki.isEmpty && trusted.contains(spki.lowercased())
    }

    /// Extract string TXT entries into a plain dictionary (ignores non-string/empty entries).
    nonisolated static func txtDictionary(_ txt: NWTXTRecord) -> [String: String] {
        var dict: [String: String] = [:]
        for (key, entry) in txt {
            if case let .string(value) = entry { dict[key] = value }
        }
        return dict
    }

    // MARK: - Discovery (regime-gated; OFF by default)

    /// Begin browsing for domestic island relays on the local network. Call ONLY when the
    /// island/censored regime is detected — this is what raises the local-network prompt.
    /// Idempotent.
    func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: Self.serviceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let trusted = Self.trustedSPKIs()
            for result in results {
                guard case let .bonjour(txtRecord) = result.metadata else { continue }
                guard let advert = Self.parseAdvert(Self.txtDictionary(txtRecord)),
                      Self.accept(spki: advert.spki, trusted: trusted) else { continue }
                let endpoint = result.endpoint
                Task { @MainActor in
                    self?.resolve(endpoint, sni: advert.sni, spki: advert.spki, wtPath: advert.wtPath)
                }
            }
        }
        browser.stateUpdateHandler = { state in
            if case let .failed(error) = state {
                Log.error("VEIL Source3: browser failed: \(error)", category: "VEIL")
            }
        }
        self.browser = browser
        browser.start(queue: .main)
        Log.info("VEIL Source3: local discovery started (\(Self.serviceType))", category: "VEIL")
    }

    /// Stop browsing and drop discovered entries (they are only valid on this LAN).
    func stop() {
        browser?.cancel()
        browser = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
        let hadEntries = !discovered.isEmpty
        discovered.removeAll()
        DiscoveredRelayStore.shared.clear()
        if hadEntries { onDiscoveredRelaysChanged?() }
    }

    /// Resolve a Bonjour endpoint to a concrete `host:port` via a short-lived connection,
    /// then record the trust-gated `DiscoveredRelay`. The advert's SPKI already matched a
    /// trusted identity; the TLS pin check on connect is the actual enforcement.
    private func resolve(_ endpoint: NWEndpoint, sni: String?, spki: String, wtPath: String?) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        connections.append(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            switch state {
            case .ready:
                var resolved: DiscoveredRelay?
                if case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint {
                    let hostString = String(describing: host).split(separator: "%").first.map(String.init)
                        ?? String(describing: host)
                    resolved = DiscoveredRelay(
                        host: hostString, port: Int(port.rawValue), sni: sni, spki: spki, wtPath: wtPath)
                }
                connection.cancel()
                Task { @MainActor in
                    guard let self else { return }
                    if let relay = resolved, !self.discovered.contains(relay) {
                        self.discovered.append(relay)
                        DiscoveredRelayStore.shared.publish(self.discovered)
                        Log.info("VEIL Source3: accepted island relay \(relay.addressWithPort)", category: "VEIL")
                        self.onDiscoveredRelaysChanged?()
                    }
                    self.connections.removeAll { $0 === connection }
                }
            case .failed, .cancelled:
                connection.cancel()
                Task { @MainActor in self?.connections.removeAll { $0 === connection } }
            default:
                break
            }
        }
        connection.start(queue: .main)
    }
}
