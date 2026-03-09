//
//  IceProxyManager.swift
//  Construct Messenger
//
//  Manages the local obfs4 proxy (construct-ice / ICE).
//
//  Architecture:
//    [Swift gRPC] → 127.0.0.1:proxyPort (plain TCP, no TLS)
//        → [Rust proxy] → Obfs4Stream → relay:443 (obfuscated)
//        → [relay VPS] → main Construct server
//
//  The proxy lives entirely inside libconstruct_core.a (C FFI symbols:
//  ice_proxy_start / ice_proxy_stop / ice_proxy_is_running / ice_proxy_port).
//  GRPCChannelManager checks isRunning and switches targets automatically.
//

import Foundation
import Combine

/// IAT (Inter-Arrival Time) obfuscation mode.
/// Higher modes resist timing analysis at the cost of latency.
enum IceIATMode: Int, CaseIterable, Identifiable {
    case none     = 0  // No timing obfuscation (fastest)
    case enabled  = 1  // 0–10 ms jitter between chunks
    case paranoid = 2  // Random chunk sizing + jitter (recommended for China/Iran)

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .none:     return "Off"
        case .enabled:  return "Enabled (jitter)"
        case .paranoid: return "Paranoid (recommended)"
        }
    }
}

/// Relay configuration — a single obfs4 bridge endpoint.
struct IceRelay: Codable, Identifiable {
    let id: UUID
    let address: String    // "relay.example.com:9443"
    let bridgeCert: String // base64 cert received from server
    let iatMode: IceIATMode

    /// Full bridge line string passed to Rust: "cert=<cert> iat-mode=<n>"
    var bridgeLine: String {
        "cert=\(bridgeCert) iat-mode=\(iatMode.rawValue)"
    }

    init(address: String, bridgeCert: String, iatMode: IceIATMode = .none) {
        self.id = UUID()
        self.address = address
        self.bridgeCert = bridgeCert
        self.iatMode = iatMode
    }

    // Codable conformance for IceIATMode (stored as rawValue Int)
    enum CodingKeys: String, CodingKey {
        case id, address, bridgeCert, iatMode
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id        = try c.decode(UUID.self, forKey: .id)
        address   = try c.decode(String.self, forKey: .address)
        bridgeCert = try c.decode(String.self, forKey: .bridgeCert)
        let raw   = (try? c.decode(Int.self, forKey: .iatMode)) ?? 0
        iatMode   = IceIATMode(rawValue: raw) ?? .none
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(address, forKey: .address)
        try c.encode(bridgeCert, forKey: .bridgeCert)
        try c.encode(iatMode.rawValue, forKey: .iatMode)
    }
}

/// Manages the construct-ice local TCP proxy for gRPC obfuscation.
@MainActor
final class IceProxyManager: ObservableObject {
    static let shared = IceProxyManager()
    private init() {}

    // MARK: - Published state

    @Published private(set) var isRunning = false
    @Published private(set) var proxyPort: UInt16 = 0
    @Published private(set) var activeRelay: IceRelay?
    @Published private(set) var lastError: String?

    // MARK: - UserDefaults keys

    private let enabledKey = "ice_enabled"
    private let relayKey   = "iceActiveRelay"
    private let certKey    = "ice_bridge_cert"

    /// Whether the user has enabled ICE obfuscation. Persists across launches.
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Whether the server has provided a bridge cert (ICE is available on this server).
    var hasCert: Bool {
        guard let cert = UserDefaults.standard.string(forKey: certKey) else { return false }
        return !cert.isEmpty
    }

    // MARK: - Start / Stop

    /// Start the local proxy for the given relay.
    /// - Returns: The local port that gRPC should connect to.
    @discardableResult
    func start(relay: IceRelay) -> UInt16? {
        if isRunning { stop() }
        lastError = nil

        var port: UInt16 = 0
        let result = relay.bridgeLine.withCString { bridgePtr in
            relay.address.withCString { addrPtr in
                ice_proxy_start(bridgePtr, addrPtr, &port)
            }
        }

        if result == 0 {
            isRunning   = true
            proxyPort   = port
            activeRelay = relay
            return port
        } else {
            lastError = "Failed to start proxy (check bridge cert)"
            return nil
        }
    }

    /// Stop the running proxy.
    func stop() {
        guard isRunning else { return }
        ice_proxy_stop()
        isRunning   = false
        proxyPort   = 0
        activeRelay = nil
    }

    /// Start with the stored relay (called at app launch if `isEnabled`).
    func startIfEnabled() {
        guard isEnabled else { return }
        guard let relay = loadStoredRelay() else { return }
        start(relay: relay)
    }

    // MARK: - Server-provided configuration

    /// Called after login/register/recovery with the cert from `AuthTokensResponse`.
    /// Saves the cert and automatically starts the proxy if ICE is enabled.
    func configureFromServer(cert: String) {
        guard !cert.isEmpty else { return }
        // Persist the cert — this is the source of truth for "ICE available"
        UserDefaults.standard.set(cert, forKey: certKey)
        let host = GRPCChannelManager.shared.currentHost
        let relay = IceRelay(address: "\(host):9443", bridgeCert: cert, iatMode: .none)
        saveRelay(relay)
        if isEnabled { start(relay: relay) }
    }

    func saveRelay(_ relay: IceRelay) {
        if let data = try? JSONEncoder().encode(relay) {
            UserDefaults.standard.set(data, forKey: relayKey)
        }
    }

    func loadStoredRelay() -> IceRelay? {
        guard let data = UserDefaults.standard.data(forKey: relayKey) else { return nil }
        return try? JSONDecoder().decode(IceRelay.self, from: data)
    }
}
