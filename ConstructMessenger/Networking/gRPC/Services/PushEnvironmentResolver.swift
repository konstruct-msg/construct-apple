//
//  PushEnvironmentResolver.swift
//  Construct Messenger
//
//  Which APNs environment minted this binary's device token.
//

import Foundation

/// Decides the APNs environment to declare when registering a device token.
///
/// Getting this wrong is not a cosmetic mislabel. The server probes only the environments the
/// token claims; APNs answers `BadDeviceToken` for a token presented to the wrong endpoint, which
/// is byte-identical to its answer for a token that is genuinely dead. The server cannot tell the
/// two apart, so it does the safe-looking thing and **deletes the token**. The app registers a
/// fresh one, which is wrong in the same way, and pushes stop arriving at all. That loop ran on
/// 2026-08-18: rejection and deletion at 13:52:23, again at 14:02:49, and by 14:08 the row was
/// gone entirely (`total_tokens=0`).
///
/// The previous implementation read `APSEnvironment` from Info.plist and asserted it "by
/// construction" matched the `aps-environment` entitlement, both expanding `$(APS_ENVIRONMENT)`
/// from the xcconfigs. They expand from the same setting and still disagree, because they are
/// fixed at different times: Info.plist at **build** time from the configuration (Beta includes
/// Release.xcconfig → `production`), the entitlement at **signing** time from the profile Xcode
/// actually used. Install a Beta build straight from Xcode and it is signed for development. The
/// build on the device that day carried exactly that pair:
///
///     Info.plist APSEnvironment  = production
///     signed aps-environment     = development
///
/// APNs follows the signature, so the token was sandbox and the app announced production.
///
/// So the signed entitlement is the authority here, read from `embedded.mobileprovision`, and the
/// build-time declaration is only a fallback. When neither can be established the answer is
/// `.unknown` — never a guess. `UNSPECIFIED` is a value the server understands: it records both
/// candidates and probes them in order (`notification_grpc.rs`, `ApnsEnvironments::both`), which
/// costs one wasted request and cannot cost the token.
enum PushEnvironmentResolver {

    enum Declared: String, Equatable {
        case sandbox
        case production
        /// Undecidable. Declare `UNSPECIFIED` and let the server probe both.
        case unknown
    }

    /// The two spellings Apple uses for `aps-environment`. Anything else is undecidable —
    /// including the empty string an unexpanded `$(APS_ENVIRONMENT)` leaves behind.
    static func parse(_ raw: String?) -> Declared {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "development": return .sandbox
        case "production":  return .production
        default:            return .unknown
        }
    }

    /// Signed entitlement first, build-time declaration second, `.unknown` rather than a guess.
    static func resolve(signedEntitlement: String?, infoPlist: String?) -> Declared {
        let signed = parse(signedEntitlement)
        return signed == .unknown ? parse(infoPlist) : signed
    }

    /// Whether the two sources both resolved and contradict each other.
    ///
    /// Worth its own function because this is the state that produced the outage, and it is
    /// invisible unless something looks for it: each source on its own is a plausible value.
    static func disagree(signedEntitlement: String?, infoPlist: String?) -> Bool {
        let signed = parse(signedEntitlement)
        let declared = parse(infoPlist)
        return signed != .unknown && declared != .unknown && signed != declared
    }

    /// `Entitlements.aps-environment` from the app's embedded provisioning profile.
    ///
    /// The profile is a CMS blob with a plain XML plist inside it. Rather than decode PKCS#7 we
    /// take the plist by its bounds, which is what every implementation of this does and needs no
    /// dependency. Returns nil off-device: a simulator build has no profile, and there the
    /// Info.plist fallback is both available and correct.
    static func apsEnvironmentFromEmbeddedProfile(in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        return apsEnvironment(inProfileData: data)
    }

    /// Split out from the file read so a test can hand it bytes.
    static func apsEnvironment(inProfileData data: Data) -> String? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), options: .backwards),
              start.lowerBound < end.upperBound
        else { return nil }

        let plistData = data[start.lowerBound..<end.upperBound]
        guard let plist = try? PropertyListSerialization.propertyList(
                  from: plistData, options: [], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any]
        else { return nil }

        return entitlements["aps-environment"] as? String
    }
}
