//
//  QRScanRouter.swift
//  Construct Messenger
//
//  Where a scanned string goes. Extracted from `QRScannerView` because the decision
//  was a chain of `if` branches inside a SwiftUI view, with nothing asserting it —
//  and a whole category of code was missing from it for as long as vouchers existed.
//
//  A `konstruct://veil-config?d=…` QR matched none of the invite prefixes and is not
//  base64-like (it contains `://`), so it fell through to the error branch and was
//  reported as "scan a Konstruct contact code". `onCodeScanned` was never called, so
//  no call site could have handled it — including the two whose only job is to.
//  A bare capability failed differently and just as silently: `isBase64Like` accepted
//  it and rewrote it as `konstruct://add?invite=…`, which the config importer then
//  read as malformed.
//
//  The scanner is shared by contact, device-link, settings and onboarding screens, so
//  it must not interpret what it lets through — it decides only *whether* a payload is
//  recognisable, and hands the string to the parent verbatim.
//

import Foundation

enum QRScanRoute: Equatable {
    /// Hand this payload to the parent's `onCodeScanned`.
    case deliver(String)
    /// Nothing here we recognise.
    case invalid
}

enum QRScanRouter {

    /// Shortest string still worth treating as a bare invite payload. Lives here, not
    /// in the view: the view is iOS-only and this decision is not.
    static let minBase64Length = 40

    static func route(_ normalized: String) -> QRScanRoute {
        // veil-front access config. Delivered verbatim: it is not an invite, and
        // wrapping it as one is what broke it before.
        if let url = URL(string: normalized), DeepLinkHandler.veilConfigBlob(from: url) != nil {
            return .deliver(normalized)
        }

        let lower = normalized.lowercased()
        // Signed dynamic invites + device-link QR only (legacy /c/ is rejected by LinkParser).
        if lower.hasPrefix("https://konstruct.cc/add") ||
           lower.hasPrefix("https://web.konstruct.cc/add") ||
           lower.hasPrefix(InviteConfig.qrCodePrefixScheme) ||
           // Device link flows (Settings → Link Replica, onboarding join-request from Desktop)
           lower.hasPrefix("konstruct://link") {
            return .deliver(normalized)
        }
        if isBase64Like(normalized) {
            return .deliver("konstruct://add?invite=\(normalized)")
        }
        return .invalid
    }

    static func isBase64Like(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minBase64Length else { return false }
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=_-"
        )
        return trimmed.rangeOfCharacter(from: allowed.inverted) == nil
    }
}
