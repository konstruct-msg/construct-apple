//
//  CensoredNetworkDetector.swift
//  Construct Messenger
//
//  Detects whether the device's SIM home carrier is in a country that
//  censors direct gRPC/TLS traffic. Used by ConnectionLoop to pre-activate
//  ICE on startup, eliminating the 3.2s cold-start penalty on censored networks.
//

import Foundation
#if os(iOS)
import CoreTelephony
#endif

enum CensoredNetworkDetector {

    private static let censoredCarrierCountries: Set<String> = [
        "ru",  // Russia
        "cn",  // China
        "ir",  // Iran
        "by",  // Belarus
        "az",  // Azerbaijan
        "uz",  // Uzbekistan
        "tm",  // Turkmenistan
        "tj",  // Tajikistan
    ]

    /// True when the device SIM's home carrier is in a country that censors
    /// direct gRPC/TLS traffic. Returns false when CoreTelephony is unavailable.
    static var isCensored: Bool {
        #if DEBUG
        if let override = _testOverride { return override }
        #endif
        return detectFromSIM()
    }

    #if DEBUG
    static var _testOverride: Bool? = nil
    #endif

    private static func detectFromSIM() -> Bool {
        #if os(iOS)
        let info = CTTelephonyNetworkInfo()
        guard let providers = info.serviceSubscriberCellularProviders else { return false }
        return providers.values.contains { carrier in
            guard let code = carrier.isoCountryCode?.lowercased() else { return false }
            return censoredCarrierCountries.contains(code)
        }
        #else
        return false
        #endif
    }
}
