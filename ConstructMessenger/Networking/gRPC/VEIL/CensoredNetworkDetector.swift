//
//  CensoredNetworkDetector.swift
//  Construct Messenger
//
//  Detects whether the device is likely in a country that censors direct
//  gRPC/TLS traffic. Uses timezone as a heuristic (CoreTelephony carrier
//  APIs were deprecated in iOS 16 and no longer return usable data).
//
//  Used by ConnectionLoop to pre-activate VEIL on startup, eliminating
//  the ~3.2s cold-start penalty of two failing direct attempts on
//  DPI-censored networks.
//
//  False positives are harmless (VEIL starts earlier, wastes a proxy start).
//  False negatives cost ~3.2s on first connection (H3 timeout + H2 timeout).
//

import Foundation

enum CensoredNetworkDetector {

    /// Timezone identifiers that correlate strongly with DPI-censored networks.
    /// Matches the region list in VeilRelaySelector.applyRegionPreference.
    private static let censoredTimezones: Set<String> = [
        // Russia (11 timezones)
        "Europe/Moscow", "Europe/Kaliningrad", "Europe/Samara", "Europe/Volgograd",
        "Asia/Yekaterinburg", "Asia/Omsk", "Asia/Krasnoyarsk", "Asia/Novosibirsk",
        "Asia/Irkutsk", "Asia/Chita", "Asia/Vladivostok", "Asia/Magadan",
        "Asia/Kamchatka", "Asia/Anadyr",
        // China (one official timezone)
        "Asia/Shanghai", "Asia/Urumqi",
        // Iran
        "Asia/Tehran",
        // Belarus
        "Europe/Minsk",
        // Central Asia
        "Asia/Baku",        // Azerbaijan
        "Asia/Tashkent",    // Uzbekistan
        "Asia/Samarkand",   // Uzbekistan
        "Asia/Ashgabat",    // Turkmenistan
        "Asia/Dushanbe",    // Tajikistan
    ]

    /// True when the device is likely in a DPI-censored country.
    /// Primary signal: GeoIPManager (IP-based, cached after first STUN lookup).
    /// Fallback: timezone heuristic (used at startup before GeoIP resolves).
    /// Used by ConnectionLoop to pre-activate VEIL on startup, eliminating
    /// the ~3.2s cold-start penalty of two failing direct attempts.
    static var isCensored: Bool {
        #if DEBUG
        if let override = _testOverride { return override }
        #endif
        let geoRegion = GeoIPManager.shared.region
        if geoRegion != .unknown { return geoRegion.isCensored }
        return detectFromTimezone()
    }

    #if DEBUG
    static var _testOverride: Bool? = nil
    #endif

    private static func detectFromTimezone() -> Bool {
        censoredTimezones.contains(TimeZone.current.identifier)
    }
}
