import Foundation

// Determines the user's geographic region from their public IP using local MMDB databases.
// Resolution flow: cached result (UserDefaults) → STUN → mmdb lookup → timezone fallback.
// The result is cached indefinitely; callers that care about freshness call resolve() again
// after a network path change.
enum GeoIPRegion: String {
    /// Russia, Belarus, Iran, China, and similar countries with active DPI/censorship.
    /// Prefer WebTunnel/obfs4 relay over direct gRPC.
    case ruLike  = "ru_like"
    /// All other countries. Prefer lowest-latency relay (typically AMS direct).
    case other   = "other"
    /// No result yet (STUN failed and no cache). Callers should fall back to timezone heuristic.
    case unknown = "unknown"

    var isCensored: Bool { self == .ruLike }
}

actor GeoIPManager {

    static let shared = GeoIPManager()

    /// GeoIP is disabled until multi-relay infrastructure is deployed. With a single
    /// veil-front relay, region-based relay selection is a no-op and the censorship
    /// signal doesn't gate connections (auto-mode is direct-first), so shipping the
    /// ~20 MB GeoLite2 databases in the bundle earns nothing. When disabled, `region`
    /// returns `.unknown` and `resolve()` short-circuits (no STUN, no mmdb lookup) so
    /// every consumer falls back to the timezone heuristic exactly as before.
    ///
    /// Re-enable when multiple relays exist: set this `true`, re-add
    /// `GeoLite2-Country.mmdb` / `GeoLite2-ASN.mmdb` to the target's Resources, and
    /// restore the `fetch_geoip.sh` build phase (see scripts/fetch_geoip.sh).
    static let isEnabled = false

    // ISO 3166-1 alpha-2 codes of countries with documented DPI / gRPC blocking.
    private static let censoredCountries: Set<String> = [
        "RU",  // Russia
        "CN",  // China
        "IR",  // Iran
        "BY",  // Belarus
        "AZ",  // Azerbaijan
        "UZ",  // Uzbekistan
        "TM",  // Turkmenistan
        "TJ",  // Tajikistan
        "KP",  // North Korea
    ]

    private static let cacheKey = "construct.geoip_region_v1"
    private static let cacheIPKey = "construct.geoip_ip_v1"

    private var resolvedRegion: GeoIPRegion = {
        guard let raw = UserDefaults.standard.string(forKey: cacheKey),
              let cached = GeoIPRegion(rawValue: raw) else { return .unknown }
        return cached
    }()

    private var resolving = false

    // MARK: - Synchronous read (safe to call from any context)

    /// Returns the most recently resolved region. `.unknown` if resolve() has not completed yet.
    nonisolated var region: GeoIPRegion {
        guard Self.isEnabled else { return .unknown }
        // Read from UserDefaults directly — safe without actor isolation
        guard let raw = UserDefaults.standard.string(forKey: Self.cacheKey),
              let r = GeoIPRegion(rawValue: raw) else { return .unknown }
        return r
    }

    // MARK: - Resolution

    /// Resolves the region in the background. Idempotent — does nothing if already resolving.
    /// Callers may await this to get the result synchronously.
    @discardableResult
    func resolve() async -> GeoIPRegion {
        guard Self.isEnabled else { return .unknown }
        #if os(macOS)
        return .unknown
        #else
        if resolvedRegion != .unknown { return resolvedRegion }
        if resolving { return resolvedRegion }
        resolving = true
        defer { resolving = false }

        let result = await performResolution()
        resolvedRegion = result
        UserDefaults.standard.set(result.rawValue, forKey: Self.cacheKey)
        Log.info("GeoIP resolved: \(result.rawValue)", category: "GeoIP")
        return result
        #endif
    }

    /// Discards the cached result and re-resolves. Call on network-path changes.
    func invalidate() {
        #if os(macOS)
        return
        #else
        resolvedRegion = .unknown
        UserDefaults.standard.removeObject(forKey: Self.cacheKey)
        UserDefaults.standard.removeObject(forKey: Self.cacheIPKey)
        #endif
    }

    // MARK: - Private

    private func performResolution() async -> GeoIPRegion {
        guard let publicIP = await STUNClient.publicIP() else {
            Log.info("GeoIP: STUN failed — returning unknown", category: "GeoIP")
            return .unknown
        }
        UserDefaults.standard.set(publicIP, forKey: Self.cacheIPKey)
        Log.info("GeoIP: public IP = \(publicIP)", category: "GeoIP")

        #if os(macOS)
        // GeoIP / mmdb lookup is skipped on macOS Desktop.
        // Desktop uses direct gRPC + TransportRouter. VEIL (when enabled) is
        // controlled by user toggle; region-based auto-probing is not required.
        Log.debug("GeoIP: skipping mmdb lookup on macOS", category: "GeoIP")
        return .unknown
        #else
        if let code = lookupCountry(ip: publicIP) {
            let region: GeoIPRegion = Self.censoredCountries.contains(code.uppercased()) ? .ruLike : .other
            Log.info("GeoIP: country=\(code) → region=\(region.rawValue)", category: "GeoIP")
            return region
        }

        Log.info("GeoIP: country lookup failed for \(publicIP) — returning unknown", category: "GeoIP")
        return .unknown
        #endif
    }

    private func lookupCountry(ip: String) -> String? {
        guard let url = Bundle.main.url(forResource: "GeoLite2-Country", withExtension: "mmdb") else {
            #if os(macOS)
            // mmdb not required on Desktop; VEIL is ticket-driven and mode=off skips it anyway.
            Log.debug("GeoIP mmdb not bundled/available (macOS Desktop)", category: "GeoIP")
            #else
            Log.info("GeoIP: GeoLite2-Country.mmdb not found in bundle", category: "GeoIP")
            #endif
            return nil
        }
        do {
            let reader = try MMDBReader(url: url)
            return reader.countryCode(for: ip)
        } catch {
            Log.info("GeoIP: mmdb read error: \(error)", category: "GeoIP")
            return nil
        }
    }

    // MARK: - Debug

    #if DEBUG
    static var _testOverrideRegion: GeoIPRegion? = nil
    #endif
}
