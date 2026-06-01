//
//  VeilRelay.swift
//  Construct Messenger
//

import Foundation

/// Higher modes resist timing analysis at the cost of latency.
enum VeilIATMode: Int, CaseIterable, Identifiable {
    case none     = 0
    case enabled  = 1
    case paranoid = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .none:     return "Off"
        case .enabled:  return "Enabled (jitter)"
        case .paranoid: return "Paranoid (recommended)"
        }
    }
}

/// Relay configuration for a single obfs4 bridge endpoint.
struct VeilRelay: Codable, Identifiable {
    let id: UUID
    /// Stable relay ID from the server manifest, for example "ams-het-1".
    let manifestId: String?
    /// Address in "host:port" form.
    let address: String
    /// obfs4 bridge cert received from the server or fallback config.
    let bridgeCert: String
    let iatMode: VeilIATMode
    /// nil = legacy plain-TCP obfs4. Empty string = TLS without SNI. Non-empty = TLS SNI.
    let tlsServerName: String?
    /// SHA-256 of DER SubjectPublicKeyInfo in hex.
    let pinnedSpki: String?
    /// WebTunnel WebSocket resource path, for example "/construct-veil".
    let wtPath: String?
    /// HTTP Host header for WebTunnel upgrade; nil means use relay hostname/SNI.
    let wtHostHeader: String?
    /// Alternative TLS SNI values for WebTunnel rotation.
    let alternativeSNIs: [String]

    /// Full bridge line passed to Rust: "cert=<cert> iat-mode=<n>".
    var bridgeLine: String {
        "cert=\(bridgeCert) iat-mode=\(iatMode.rawValue)"
    }

    var supportsWebTunnel: Bool { wtPath != nil }

    /// True when TLS SNI points to a CDN/domain-fronting host rather than the relay host.
    var isCDNFronted: Bool {
        guard let sni = tlsServerName, !sni.isEmpty else { return false }
        let hostname = address.components(separatedBy: ":").first ?? address
        return sni != hostname
    }

    init(address: String, bridgeCert: String, iatMode: VeilIATMode = .none,
         tlsServerName: String? = nil, pinnedSpki: String? = nil,
         wtPath: String? = nil, wtHostHeader: String? = nil,
         alternativeSNIs: [String] = [], manifestId: String? = nil) {
        self.id = UUID()
        self.manifestId = manifestId
        self.address = address
        self.bridgeCert = bridgeCert
        self.iatMode = iatMode
        self.tlsServerName = tlsServerName
        self.pinnedSpki = pinnedSpki
        self.wtPath = wtPath
        self.wtHostHeader = wtHostHeader
        self.alternativeSNIs = alternativeSNIs
    }

    enum CodingKeys: String, CodingKey {
        case id, address, bridgeCert, iatMode, tlsServerName, pinnedSpki, wtPath, wtHostHeader
        case alternativeSNIs = "alternativeSNIs"
        case manifestId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        manifestId = try? c.decode(String.self, forKey: .manifestId)
        address = try c.decode(String.self, forKey: .address)
        bridgeCert = try c.decode(String.self, forKey: .bridgeCert)
        let raw = (try? c.decode(Int.self, forKey: .iatMode)) ?? 1
        iatMode = VeilIATMode(rawValue: raw) ?? .enabled
        tlsServerName = try? c.decode(String.self, forKey: .tlsServerName)
        pinnedSpki = try? c.decode(String.self, forKey: .pinnedSpki)
        wtPath = try? c.decode(String.self, forKey: .wtPath)
        wtHostHeader = try? c.decode(String.self, forKey: .wtHostHeader)
        alternativeSNIs = (try? c.decode([String].self, forKey: .alternativeSNIs)) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try? c.encode(manifestId, forKey: .manifestId)
        try c.encode(address, forKey: .address)
        try c.encode(bridgeCert, forKey: .bridgeCert)
        try c.encode(iatMode.rawValue, forKey: .iatMode)
        try? c.encode(tlsServerName, forKey: .tlsServerName)
        try? c.encode(pinnedSpki, forKey: .pinnedSpki)
        try? c.encode(wtPath, forKey: .wtPath)
        try? c.encode(wtHostHeader, forKey: .wtHostHeader)
        if !alternativeSNIs.isEmpty { try? c.encode(alternativeSNIs, forKey: .alternativeSNIs) }
    }
}
