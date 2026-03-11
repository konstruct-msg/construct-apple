//
//  IceCertFetcher.swift
//  Construct Messenger
//
//  Fetches the ICE bridge cert from the .well-known HTTPS endpoint on the
//  Cloudflare-proxied domain. Used as level 3 in the cert fallback chain:
//
//    1. AuthTokensResponse (after login) → saved to Keychain by IceProxyManager
//    2. Keychain cache                   → IceProxyManager.getIceBridgeCert()
//    3. https://<inviteHost>/.well-known/ice-cert   ← this file
//    4. Hardcoded in binary              → ICEConfig.hardcodedBridgeCert
//
//  The endpoint returns: {"cert":"<base64>","iat_mode":0}
//  No authentication required — the cert is the server's public obfs4 identity.

import Foundation

private struct IceCertWellKnown: Decodable {
    let cert: String
    let iatMode: Int

    enum CodingKeys: String, CodingKey {
        case cert
        case iatMode = "iat_mode"
    }
}

actor IceCertFetcher {
    static let shared = IceCertFetcher()
    private init() {}

    private let timeout: TimeInterval = 8.0

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
}
