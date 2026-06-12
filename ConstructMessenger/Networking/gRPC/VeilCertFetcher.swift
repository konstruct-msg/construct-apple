//
//  VeilCertFetcher.swift
//  Construct Messenger
//
//  Fetches the VEIL bridge cert and relay config from .well-known endpoints.
//  Cert fallback chain (level 3):
//    1. AuthTokensResponse (after login) → saved to Keychain by VeilProxyManager
//    2. Keychain cache                   → VeilProxyManager.getVEILBridgeCert()
//    3. https://konstruct.cc/.well-known/veil-cert   ← this file
//    4. Hardcoded in binary              → VEILConfig.hardcodedBridgeCert
//
//  Relay config (with SPKI pins) fallback chain:
//    1. https://konstruct.cc/.well-known/construct-server (Ed25519 signed)
//    2. UserDefaults cache (last valid fetch)
//    3. Hardcoded in VEILConfig

import CryptoKit
import Foundation

// MARK: - Relay config model

struct RelayInfo: Codable {
    let id: String
    let addr: String
    let port: Int
    let domain: String
    let sni: String
    let spkiSha256: String
    /// obfs4 bridge cert for this relay's own keypair.
    /// When present, overrides the AMS cert so new relays are fully OTA-updatable
    /// without a binary release. nil → falls back to the AMS cert (legacy behaviour).
    let bridgeCert: String?
    /// WebSocket resource path for WebTunnel (VEIL v2), e.g. "/construct-veil".
    /// nil / empty → relay does not advertise WebTunnel support.
    let wtPath: String?
    /// Optional HTTP Host header override for the WebSocket upgrade request.
    /// nil → falls back to `sni`.
    let wtHostHeader: String?
    /// IAT mode pushed by server. Defaults to `.enabled` (1) when absent.
    let iatMode: VeilIATMode
    /// Additional TLS SNI values to try for WebTunnel on this relay before falling back to obfs4.
    /// Allows domain-fronting rotation without a binary update.
    /// nil / empty → no SNI alternatives available.
    let alternativeSNIs: [String]?
    /// Unix timestamp when this relay's TLS certificate expires.
    /// nil → expiry unknown (server hasn't pushed this data yet).
    let certExpiresAt: Double?

    var addressWithPort: String { "\(addr):\(port)" }

    enum CodingKeys: String, CodingKey {
        case id, addr, port, domain, sni
        case spkiSha256      = "spki_sha256"
        case bridgeCert      = "bridge_cert"
        case wtPath          = "wt_path"
        case wtHostHeader    = "wt_host_header"
        case iatMode         = "iat_mode"
        case alternativeSNIs = "alternative_snis"
        case certExpiresAt   = "cert_expires_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id              = try c.decode(String.self,  forKey: .id)
        addr            = try c.decode(String.self,  forKey: .addr)
        port            = try c.decode(Int.self,     forKey: .port)
        domain          = try c.decode(String.self,  forKey: .domain)
        sni             = try c.decode(String.self,  forKey: .sni)
        spkiSha256      = try c.decode(String.self,  forKey: .spkiSha256)
        bridgeCert      = try c.decodeIfPresent(String.self, forKey: .bridgeCert)
        wtPath          = try c.decodeIfPresent(String.self, forKey: .wtPath)
        wtHostHeader    = try c.decodeIfPresent(String.self, forKey: .wtHostHeader)
        alternativeSNIs = try c.decodeIfPresent([String].self, forKey: .alternativeSNIs)
        certExpiresAt   = try c.decodeIfPresent(Double.self, forKey: .certExpiresAt)
        let rawIat  = (try? c.decodeIfPresent(Int.self, forKey: .iatMode)) ?? nil
        iatMode     = rawIat.flatMap { VeilIATMode(rawValue: $0) } ?? .enabled
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id,           forKey: .id)
        try c.encode(addr,         forKey: .addr)
        try c.encode(port,         forKey: .port)
        try c.encode(domain,       forKey: .domain)
        try c.encode(sni,          forKey: .sni)
        try c.encode(spkiSha256,   forKey: .spkiSha256)
        try c.encodeIfPresent(bridgeCert,      forKey: .bridgeCert)
        try c.encodeIfPresent(wtPath,          forKey: .wtPath)
        try c.encodeIfPresent(wtHostHeader,    forKey: .wtHostHeader)
        try c.encodeIfPresent(alternativeSNIs, forKey: .alternativeSNIs)
        try c.encodeIfPresent(certExpiresAt,   forKey: .certExpiresAt)
        try c.encode(iatMode.rawValue,         forKey: .iatMode)
    }
}

// MARK: - Private wire types

private struct VeilCertWellKnown: Decodable {
    let cert: String
    let iatMode: Int

    enum CodingKeys: String, CodingKey {
        case cert
        case iatMode = "iat_mode"
    }
}

private struct ConstructServerWellKnown: Decodable {
    struct VEILSection: Decodable {
        let primary: String?
        let relays: [RelayInfo]?
        let relayRegions: [VEILRelayRegion]?
        /// Relay IDs that have been retired. Clients with any of these as their
        /// active relay should rotate immediately after fetching a fresh config.
        let deprecatedIds: [String]?

        enum CodingKeys: String, CodingKey {
            case primary, relays
            case relayRegions   = "relay_regions"
            case deprecatedIds  = "deprecated_ids"
        }
    }
    let version: String?
    let veil: VEILSection?
    let signedAt: String?
    let signature: String?
    /// Ed25519 public key (base64) used to sign pre-key bundles and KT Signed Tree Heads.
    let bundleSigningKey: String?

    enum CodingKeys: String, CodingKey {
        case version, ice, signature
        case signedAt = "signed_at"
        case bundleSigningKey = "bundle_signing_key"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // version and signed_at may be Int (sign_relay_manifest.py) or String — accept both
        if let s = try? c.decodeIfPresent(String.self, forKey: .version) {
            version = s
        } else if let i = try? c.decodeIfPresent(Int.self, forKey: .version) {
            version = String(i)
        } else {
            version = nil
        }
        if let s = try? c.decodeIfPresent(String.self, forKey: .signedAt) {
            signedAt = s
        } else if let i = try? c.decodeIfPresent(Int.self, forKey: .signedAt) {
            signedAt = String(i)
        } else {
            signedAt = nil
        }
        veil              = try c.decodeIfPresent(VEILSection.self, forKey: .ice)
        signature        = try c.decodeIfPresent(String.self,     forKey: .signature)
        bundleSigningKey = try c.decodeIfPresent(String.self,     forKey: .bundleSigningKey)
    }
}

// MARK: - VeilCertFetcher

actor VeilCertFetcher {
    static let shared = VeilCertFetcher()
    private init() {}

    private let timeout: TimeInterval = NetworkTiming.VEIL.certFetchTimeoutHTTPS

    // MPTCP .handover: OS migrates in-flight requests to cellular when WiFi drops,
    // preventing cert/relay-config fetches from failing on interface transitions.
    // MPTCP is iOS-only; macOS uses a standard URLSession.
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        #if os(iOS)
        config.multipathServiceType = .handover
        #endif
        return URLSession(configuration: config)
    }()

    // UserDefaults key for cached relay infos (JSON-encoded [RelayInfo])
    private static let cachedRelayInfosKey = "construct.ice_relay_infos"
    /// UserDefaults key for deprecated relay IDs pushed by the server (JSON-encoded [String]).
    private static let cachedDeprecatedIdsKey = "construct.ice_deprecated_relay_ids"
    /// UserDefaults key for cached server Ed25519 bundle-signing public key (raw Data, 32 bytes).
    static let cachedBundleSigningKeyKey = "construct.bundle_signing_key"

    /// Returns the set of relay IDs the server has marked as deprecated.
    /// Clients whose active relay's manifest ID appears in this set should rotate immediately.
    static func cachedDeprecatedIdsSync() -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: cachedDeprecatedIdsKey),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(ids)
    }

    // MARK: - Bridge cert

    /// Fetch the ICE bridge cert from `https://konstruct.cc/.well-known/ice-cert`.
    /// Returns nil on any network or parse error.
    func fetchFromHTTPS() async -> String? {
        let urlString = "https://\(ServerConfig.inviteHost)/.well-known/ice-cert"
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                Log.debug("ICE .well-known returned non-200", category: "ICE")
                return nil
            }
            let parsed = try JSONDecoder().decode(VeilCertWellKnown.self, from: data)
            guard !parsed.cert.isEmpty else { return nil }
            Log.info("ICE cert fetched via .well-known", category: "ICE")
            return parsed.cert
        } catch {
            Log.debug("ICE .well-known fetch error: \(error)", category: "ICE")
            return nil
        }
    }

    // MARK: - Relay config (signed)

    /// Fetch, verify, and cache the relay config from `.well-known/construct-server`.
    ///
    /// Tries the mirror URL(s) in parallel. The first response that
    /// - returns HTTP 200, AND
    /// - passes Ed25519 signature verification
    /// wins and is persisted to UserDefaults.
    ///
    /// Source: konstruct.cc primary. The `construct-relay` GitHub-raw mirror was
    /// removed when obfs4/WebTunnel were retired in favour of veil-front
    /// (2026-06-12); the veil-front relay is hardcoded and per-user tickets are
    /// delivered out-of-band, so this legacy manifest no longer needs a RU mirror.
    @discardableResult
    func fetchAndCacheRelayConfig() async -> [RelayInfo]? {
        let mirrorURLs: [String] = [
            "https://\(ServerConfig.inviteHost)/.well-known/construct-server",
        ]

        if let relays = await fetchVerifiedRelayConfig(from: mirrorURLs) {
            return relays
        }
        Log.debug("All construct-server mirrors failed — using cache", category: "ICE")
        return Self.cachedRelayInfosSync()
    }

    /// Races all provided URLs; returns the first verified result, nil if all fail.
    private func fetchVerifiedRelayConfig(from urls: [String]) async -> [RelayInfo]? {
        return await withTaskGroup(of: [RelayInfo]?.self) { group in
            for urlString in urls {
                guard let url = URL(string: urlString) else { continue }
                group.addTask { [self] in
                    do {
                        var request = URLRequest(url: url, timeoutInterval: self.timeout)
                        request.cachePolicy = .reloadIgnoringLocalCacheData
                        let (data, response) = try await self.session.data(for: request)
                        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                            Log.debug("\(url.host ?? "") returned non-200", category: "ICE")
                            return nil
                        }
                        guard try self.verifySignature(data) else {
                            Log.error("\(url.host ?? "") signature invalid — ignoring", category: "ICE")
                            return nil
                        }
                        let parsed = try JSONDecoder().decode(ConstructServerWellKnown.self, from: data)
                        guard let relays = parsed.veil?.relays, !relays.isEmpty else { return nil }

                        // Persist to UserDefaults — safe from any task since UserDefaults is thread-safe
                        if let encoded = try? JSONEncoder().encode(relays) {
                            UserDefaults.standard.set(encoded, forKey: Self.cachedRelayInfosKey)
                        }
                        if let keyB64 = parsed.bundleSigningKey,
                           let keyData = Data(base64Encoded: keyB64) {
                            UserDefaults.standard.set(keyData, forKey: Self.cachedBundleSigningKeyKey)
                        }
                        let addressList = relays.map(\.addressWithPort)
                        UserDefaults.standard.set(addressList, forKey: VEILConfig.cachedRelayListKey)
                        if let regions = parsed.veil?.relayRegions,
                           let regionsData = try? JSONEncoder().encode(regions) {
                            UserDefaults.standard.set(regionsData, forKey: VEILConfig.cachedRelayRegionsKey)
                        }
                        // Persist deprecated relay IDs so loadStoredRelay() can evict stale cache.
                        let deprecatedIds = parsed.veil?.deprecatedIds ?? []
                        if let encodedDeprecated = try? JSONEncoder().encode(deprecatedIds) {
                            UserDefaults.standard.set(encodedDeprecated, forKey: Self.cachedDeprecatedIdsKey)
                        }

                        let deprecatedNote = deprecatedIds.isEmpty ? "" : " (deprecated: \(deprecatedIds.joined(separator: ", ")))"
                        Log.info("Relay config via \(url.host ?? "?"): \(relays.count) relay(s)\(deprecatedNote)", category: "VEIL")
                        return relays
                    } catch {
                        Log.debug("\(url.host ?? "") fetch error: \(error)", category: "VEIL")
                        return nil
                    }
                }
            }

            // Return first non-nil result; cancel remaining tasks
            for await result in group {
                if let relays = result {
                    group.cancelAll()
                    return relays
                }
            }
            return nil
        }
    }

    /// Synchronous read of cached relay infos directly from UserDefaults.
    /// Safe to call from non-async contexts (UserDefaults reads are thread-safe).
    static func cachedRelayInfosSync() -> [RelayInfo]? {
        guard let data = UserDefaults.standard.data(forKey: cachedRelayInfosKey),
              let relays = try? JSONDecoder().decode([RelayInfo].self, from: data),
              !relays.isEmpty else { return nil }
        return relays
    }

    /// Synchronous SPKI pin lookup for non-async contexts (e.g. makeRelay).
    static func spkiPinSync(for address: String) -> String? {
        if let relay = cachedRelayInfosSync()?.first(where: { $0.addressWithPort == address }) {
            return relay.spkiSha256.isEmpty ? nil : relay.spkiSha256
        }
        return nil
    }

    /// Synchronous bridge-cert lookup for non-async contexts.
    /// Returns the obfs4 bridge cert specific to this relay (from server config), or nil to
    /// fall back to the AMS cert. Enables new relays added via OTA without a binary update.
    static func bridgeCertSync(for address: String) -> String? {
        if let relay = cachedRelayInfosSync()?.first(where: { $0.addressWithPort == address }),
           let cert = relay.bridgeCert, !cert.isEmpty {
            return cert
        }
        return VEILConfig.hardcodedRelayCerts[address]
    }

    /// Synchronous WebTunnel path lookup for non-async contexts.
    /// Returns the WebSocket resource path (e.g. "/construct-veil") if the relay supports
    /// WebTunnel, or nil if it only supports obfs4.
    static func wtPathSync(for address: String) -> String? {
        if let relay = cachedRelayInfosSync()?.first(where: { $0.addressWithPort == address }),
           let path = relay.wtPath, !path.isEmpty {
            return path
        }
        return VEILConfig.hardcodedRelayWTPaths[address]
    }

    /// Synchronous WebTunnel Host header lookup for non-async contexts.
    /// Returns nil when the server config has no override — caller should fall back to SNI.
    static func wtHostHeaderSync(for address: String) -> String? {
        if let relay = cachedRelayInfosSync()?.first(where: { $0.addressWithPort == address }),
           let host = relay.wtHostHeader, !host.isEmpty {
            return host
        }
        return nil
    }

    /// Remove a single relay from the UserDefaults SPKI/config cache.
    /// Forces the next call to spkiPinSync to fall back to the hardcoded pin.
    /// Use this when a relay's TLS cert was rotated and the cached SPKI is stale.
    static func evictRelayFromCache(_ address: String) {
        guard var relays = cachedRelayInfosSync() else { return }
        relays.removeAll { $0.addressWithPort == address }
        if let encoded = try? JSONEncoder().encode(relays) {
            UserDefaults.standard.set(encoded, forKey: cachedRelayInfosKey)
            Log.info("Evicted relay \(address) from SPKI cache", category: "VEIL")
        }
    }

    /// Synchronous SNI lookup for non-async contexts.
    static func sniSync(for address: String) -> String? {
        if let relay = cachedRelayInfosSync()?.first(where: { $0.addressWithPort == address }) {
            return relay.sni.isEmpty ? nil : relay.sni
        }
        return VEILConfig.hardcodedRelaySNIs[address]
    }

    /// Synchronous alternative SNI list for non-async contexts.
    /// Returns all alternative SNIs pushed by the server for this relay, or hardcoded fallback.
    static func alternativeSNIsSync(for address: String) -> [String] {
        if let relay = cachedRelayInfosSync()?.first(where: { $0.addressWithPort == address }),
           let alts = relay.alternativeSNIs, !alts.isEmpty {
            return alts
        }
        return VEILConfig.hardcodedRelayAlternativeSNIs[address] ?? []
    }

    /// TLS certificate expiry date for a relay, as reported by the server config.
    /// Returns nil when the relay is not in cache or the server hasn't pushed expiry data.
    static func certExpiresAtSync(for address: String) -> Date? {
        guard let ts = cachedRelayInfosSync()?.first(where: { $0.addressWithPort == address })?.certExpiresAt else {
            return nil
        }
        return Date(timeIntervalSince1970: ts)
    }

    /// IAT mode pushed by server for this relay. Returns nil when relay is not in cache
    /// (caller should fall back to `.enabled`).
    static func iatModeSync(for address: String) -> VeilIATMode? {
        cachedRelayInfosSync()?.first(where: { $0.addressWithPort == address })?.iatMode
    }

    // MARK: - Legacy shim (backward compat)

    /// Deprecated: use `fetchAndCacheRelayConfig()`. Kept for callers not yet migrated.
    @discardableResult
    func fetchAndCacheRelayList() async -> [String]? {
        let relays = await fetchAndCacheRelayConfig()
        return relays?.map(\.addressWithPort)
    }

    // MARK: - Ed25519 signature verification

    nonisolated private func verifySignature(_ data: Data) throws -> Bool {
        // 1. Parse as JSON object
        guard var jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sigField = jsonObject["signature"] as? String,
              sigField.hasPrefix("ed25519:") else {
            Log.debug("construct-server: missing or malformed signature field", category: "VEIL")
            return false
        }

        // 2. Extract base64url signature bytes
        let b64url = String(sigField.dropFirst("ed25519:".count))
        guard let sigData = Data(base64URLEncoded: b64url) else {
            Log.debug("construct-server: failed to decode signature", category: "VEIL")
            return false
        }

        // 3. Remove signature field, produce canonical JSON (sorted keys, compact)
        jsonObject.removeValue(forKey: "signature")
        let canonical = try JSONSerialization.data(
            withJSONObject: jsonObject,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )

        // 4. Load public key
        guard let pubKeyData = Data(hexString: VEILConfig.relayConfigSigningKey) else {
            Log.error("relayConfigSigningKey is not valid hex", category: "VEIL")
            return false
        }
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: pubKeyData)

        // 5. Verify
        return publicKey.isValidSignature(sigData, for: canonical)
    }
}

// MARK: - Data helpers

private extension Data {
    /// Decode base64url (no padding) string to Data.
    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        self.init(base64Encoded: base64)
    }

    /// Decode a lowercase hex string to Data.
    init?(hexString: String) {
        let hex = hexString.lowercased()
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}

