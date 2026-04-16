//
//  IceCertFetcher.swift
//  Construct Messenger
//
//  Fetches the ICE bridge cert and relay config from .well-known endpoints.
//  Cert fallback chain (level 3):
//    1. AuthTokensResponse (after login) → saved to Keychain by IceProxyManager
//    2. Keychain cache                   → IceProxyManager.getIceBridgeCert()
//    3. https://konstruct.cc/.well-known/ice-cert   ← this file
//    4. Hardcoded in binary              → ICEConfig.hardcodedBridgeCert
//
//  Relay config (with SPKI pins) fallback chain:
//    1. https://konstruct.cc/.well-known/construct-server (Ed25519 signed)
//    2. UserDefaults cache (last valid fetch)
//    3. Hardcoded in ICEConfig

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
    /// WebSocket resource path for WebTunnel (ICE v2), e.g. "/construct-ice".
    /// nil / empty → relay does not advertise WebTunnel support.
    let wtPath: String?
    /// Optional HTTP Host header override for the WebSocket upgrade request.
    /// nil → falls back to `sni`.
    let wtHostHeader: String?

    var addressWithPort: String { "\(addr):\(port)" }

    enum CodingKeys: String, CodingKey {
        case id, addr, port, domain, sni
        case spkiSha256  = "spki_sha256"
        case wtPath      = "wt_path"
        case wtHostHeader = "wt_host_header"
    }
}

// MARK: - Private wire types

private struct IceCertWellKnown: Decodable {
    let cert: String
    let iatMode: Int

    enum CodingKeys: String, CodingKey {
        case cert
        case iatMode = "iat_mode"
    }
}

private struct ConstructServerWellKnown: Decodable {
    struct ICESection: Decodable {
        let primary: String?
        let relays: [RelayInfo]?
    }
    let version: String?
    let ice: ICESection?
    let signedAt: String?
    let signature: String?
    /// Ed25519 public key (base64) used to sign pre-key bundles and KT Signed Tree Heads.
    let bundleSigningKey: String?

    enum CodingKeys: String, CodingKey {
        case version, ice, signature
        case signedAt = "signed_at"
        case bundleSigningKey = "bundle_signing_key"
    }
}

// MARK: - IceCertFetcher

actor IceCertFetcher {
    static let shared = IceCertFetcher()
    private init() {}

    private let timeout: TimeInterval = NetworkTiming.ICE.certFetchTimeoutHTTPS

    // UserDefaults key for cached relay infos (JSON-encoded [RelayInfo])
    private static let cachedRelayInfosKey = "construct.ice_relay_infos"
    /// UserDefaults key for cached server Ed25519 bundle-signing public key (raw Data, 32 bytes).
    static let cachedBundleSigningKeyKey = "construct.bundle_signing_key"

    // MARK: - Bridge cert

    /// Fetch the ICE bridge cert from `https://konstruct.cc/.well-known/ice-cert`.
    /// Returns nil on any network or parse error.
    func fetchFromHTTPS() async -> String? {
        let urlString = "https://\(ServerConfig.inviteHost)/.well-known/ice-cert"
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                Log.debug("🧊 ICE .well-known returned non-200", category: "ICE")
                return nil
            }
            let parsed = try JSONDecoder().decode(IceCertWellKnown.self, from: data)
            guard !parsed.cert.isEmpty else { return nil }
            Log.info("🧊 ICE cert fetched via .well-known", category: "ICE")
            return parsed.cert
        } catch {
            Log.debug("🧊 ICE .well-known fetch error: \(error)", category: "ICE")
            return nil
        }
    }

    // MARK: - Relay config (signed)

    /// Fetch, verify, and cache the relay config from `.well-known/construct-server`.
    /// The config is signed with Ed25519; invalid signatures are rejected.
    /// On success, caches `[RelayInfo]` in UserDefaults.
    /// Returns cached relays on network failure, nil if no cache exists.
    @discardableResult
    func fetchAndCacheRelayConfig() async -> [RelayInfo]? {
        let urlString = "https://\(ServerConfig.inviteHost)/.well-known/construct-server"
        guard let url = URL(string: urlString) else { return Self.cachedRelayInfosSync() }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                Log.debug("🧊 construct-server returned non-200", category: "ICE")
                return Self.cachedRelayInfosSync()
            }

            guard try verifySignature(data) else {
                Log.error("🧊 construct-server signature invalid — ignoring response", category: "ICE")
                return Self.cachedRelayInfosSync()
            }

            let parsed = try JSONDecoder().decode(ConstructServerWellKnown.self, from: data)
            guard let relays = parsed.ice?.relays, !relays.isEmpty else {
                return Self.cachedRelayInfosSync()
            }

            // Persist to UserDefaults
            if let encoded = try? JSONEncoder().encode(relays) {
                UserDefaults.standard.set(encoded, forKey: Self.cachedRelayInfosKey)
            }

            // Cache bundle signing key for KT verification
            if let keyB64 = parsed.bundleSigningKey,
               let keyData = Data(base64Encoded: keyB64) {
                UserDefaults.standard.set(keyData, forKey: Self.cachedBundleSigningKeyKey)
            }

            // Keep old relay-list key in sync for code that hasn't migrated yet
            let addressList = relays.map(\.addressWithPort)
            UserDefaults.standard.set(addressList, forKey: ICEConfig.cachedRelayListKey)

            Log.info("🧊 Relay config updated: \(relays.count) relay(s)", category: "ICE")
            return relays
        } catch {
            Log.debug("🧊 construct-server fetch error: \(error)", category: "ICE")
            return Self.cachedRelayInfosSync()
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
        if address == ICEConfig.mskRelayAddress {
            return ICEConfig.mskRelayPinnedSPKI.isEmpty ? nil : ICEConfig.mskRelayPinnedSPKI
        }
        return nil
    }

    /// Synchronous WebTunnel path lookup for non-async contexts.
    /// Returns the WebSocket resource path (e.g. "/construct-ice") if the relay supports
    /// WebTunnel, or nil if it only supports obfs4.
    static func wtPathSync(for address: String) -> String? {
        if let relay = cachedRelayInfosSync()?.first(where: { $0.addressWithPort == address }),
           let path = relay.wtPath, !path.isEmpty {
            return path
        }
        return ICEConfig.hardcodedRelayWTPaths[address]
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
            Log.info("🧊 Evicted relay \(address) from SPKI cache", category: "ICE")
        }
    }

    /// Synchronous SNI lookup for non-async contexts.
    static func sniSync(for address: String) -> String? {
        if let relay = cachedRelayInfosSync()?.first(where: { $0.addressWithPort == address }) {
            return relay.sni.isEmpty ? nil : relay.sni
        }
        return ICEConfig.hardcodedRelaySNIs[address]
    }

    // MARK: - Legacy shim (backward compat)

    /// Deprecated: use `fetchAndCacheRelayConfig()`. Kept for callers not yet migrated.
    @discardableResult
    func fetchAndCacheRelayList() async -> [String]? {
        let relays = await fetchAndCacheRelayConfig()
        return relays?.map(\.addressWithPort)
    }

    // MARK: - Ed25519 signature verification

    private func verifySignature(_ data: Data) throws -> Bool {
        // 1. Parse as JSON object
        guard var jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sigField = jsonObject["signature"] as? String,
              sigField.hasPrefix("ed25519:") else {
            Log.debug("🧊 construct-server: missing or malformed signature field", category: "ICE")
            return false
        }

        // 2. Extract base64url signature bytes
        let b64url = String(sigField.dropFirst("ed25519:".count))
        guard let sigData = Data(base64URLEncoded: b64url) else {
            Log.debug("🧊 construct-server: failed to decode signature", category: "ICE")
            return false
        }

        // 3. Remove signature field, produce canonical JSON (sorted keys, compact)
        jsonObject.removeValue(forKey: "signature")
        let canonical = try JSONSerialization.data(
            withJSONObject: jsonObject,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )

        // 4. Load public key
        guard let pubKeyData = Data(hexString: ICEConfig.relayConfigSigningKey) else {
            Log.error("🧊 relayConfigSigningKey is not valid hex", category: "ICE")
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

