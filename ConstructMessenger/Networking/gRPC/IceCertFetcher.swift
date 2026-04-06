//
//  IceCertFetcher.swift
//  Construct Messenger
//
//  Fetches the ICE bridge cert and relay list from .well-known endpoints.
//  Used as level 3 in the cert fallback chain:
//
//    1. AuthTokensResponse (after login) → saved to Keychain by IceProxyManager
//    2. Keychain cache                   → IceProxyManager.getIceBridgeCert()
//    3. https://<inviteHost>/.well-known/ice-cert   ← this file
//    4. Hardcoded in binary              → ICEConfig.hardcodedBridgeCert
//
//  The cert endpoint returns: {"cert":"<base64>","iat_mode":0}
//
//  Relay list is fetched from:
//    https://ams.konstruct.cc/.well-known/construct-server
//  Response: {"ice":{"primary":"ice.ams.konstruct.cc:443","relays":["ice.msk.konstruct.cc:9443"]}}
//  Result is cached in UserDefaults under ICEConfig.cachedRelayListKey.

import Foundation

private struct IceCertWellKnown: Decodable {
    let cert: String
    let iatMode: Int

    enum CodingKeys: String, CodingKey {
        case cert
        case iatMode = "iat_mode"
    }
}

private struct ConstructServerWellKnown: Decodable {
    struct ICEEndpoints: Decodable {
        let primary: String?
        let relays: [String]?
        let relayRegions: [ICERelayRegion]?

        enum CodingKeys: String, CodingKey {
            case primary
            case relays
            case relayRegions = "relay_regions"
        }
    }
    let ice: ICEEndpoints?
}

actor IceCertFetcher {
    static let shared = IceCertFetcher()
    private init() {}

    private let timeout: TimeInterval = NetworkTiming.ICE.certFetchTimeoutHTTPS

    /// Fetch the ICE bridge cert from `https://<inviteHost>/.well-known/ice-cert`.
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

    /// Fetch the relay list and relay-region config from `https://ams.konstruct.cc/.well-known/construct-server`.
    ///
    /// On success, updates UserDefaults caches:
    ///   - `ICEConfig.cachedRelayListKey`    → relay address strings
    ///   - `ICEConfig.cachedRelayRegionsKey` → JSON-encoded `[ICERelayRegion]` (optional field)
    ///
    /// Returns the relay address strings, or nil if the server is unreachable or unparseable.
    @discardableResult
    func fetchAndCacheRelayList() async -> [String]? {
        let urlString = "https://ams.konstruct.cc/.well-known/construct-server"
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                Log.debug("🧊 construct-server .well-known returned non-200", category: "ICE")
                return nil
            }
            let parsed = try JSONDecoder().decode(ConstructServerWellKnown.self, from: data)
            guard let relays = parsed.ice?.relays, !relays.isEmpty else { return nil }

            // Cache relay list.
            UserDefaults.standard.set(relays, forKey: ICEConfig.cachedRelayListKey)
            Log.info("🧊 ICE relay list updated: \(relays)", category: "ICE")

            // Cache relay-region rules (optional — server may not include them yet).
            if let regions = parsed.ice?.relayRegions, !regions.isEmpty {
                if let encoded = try? JSONEncoder().encode(regions) {
                    UserDefaults.standard.set(encoded, forKey: ICEConfig.cachedRelayRegionsKey)
                    Log.info("🧊 ICE relay regions updated: \(regions.count) rule(s)", category: "ICE")
                }
            }

            return relays
        } catch {
            Log.debug("🧊 construct-server .well-known fetch error: \(error)", category: "ICE")
            return nil
        }
    }
}
