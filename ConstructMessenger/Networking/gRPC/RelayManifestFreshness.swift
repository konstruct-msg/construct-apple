//
//  RelayManifestFreshness.swift
//  Construct Messenger
//
//  Whether a signed relay manifest is newer than the one we already trusted.
//

import Foundation

/// The one decision that makes more than one manifest source safe.
///
/// `.well-known/construct-server` is Ed25519-signed, so the domain it arrives from is a location
/// and not a trust anchor — which is what lets us serve it from a mirror at all. But a signature
/// says who wrote a manifest, never when, and an old manifest we signed ourselves verifies exactly
/// as well as the current one. `VeilCertFetcher` races its sources and takes the first that
/// verifies, so without this the winner is whichever host answers fastest, and a stale mirror wins
/// on latency alone. Someone able to slow or block the fresh source turns that into a chosen
/// rollback: an earlier relay list, earlier SPKI pins, and an earlier `bundle_signing_key` — the
/// key stealth sender-certificate and prekey-bundle verification are checked against.
///
/// `signed_at` was already parsed, with a decoder careful enough to accept both a string and an
/// epoch integer, and then never read by anything. That was harmless while there was one source.
/// It stops being harmless the moment there are two, which is why this landed in the same change
/// as the mirror rather than after it.
enum RelayManifestFreshness {

    enum Verdict: Equatable {
        /// Newer than what we hold, or the first manifest we have ever seen.
        case accept
        /// Correctly signed, but not newer. A mirror that has not caught up yet, or a rollback.
        case rejectOlder
        /// Carries no usable `signed_at` while we already hold one that does.
        case rejectUndatable
    }

    /// `signed_at` as an instant. The manifest signer has emitted both forms — ISO-8601 from the
    /// current tooling, epoch seconds from `sign_relay_manifest.py` — so both are read here rather
    /// than at one call site.
    static func instant(from raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let epoch = TimeInterval(raw) {
            // Guard against an ISO-8601 year parsing as an epoch ("2026" → 1970-01-01T00:33:46Z).
            // Any real signing time is far past this; any real epoch value is far above it.
            return epoch > 100_000 ? Date(timeIntervalSince1970: epoch) : nil
        }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: raw) { return d }
        return ISO8601DateFormatter().date(from: raw)
    }

    /// Whether a freshly fetched manifest may replace what we already trust.
    ///
    /// Equal instants **accept**: two mirrors serving the same manifest is the normal case, and
    /// rejecting an identical copy would mean the loser of the race invalidates the winner's work
    /// on a second run.
    ///
    /// A candidate with no readable `signed_at` is refused once we hold a dated one — otherwise
    /// stripping the field is all a rollback needs. With nothing cached it is accepted, or a
    /// device that has never fetched could never start.
    static func verdict(candidateSignedAt: String?, cachedSignedAt: String?) -> Verdict {
        guard let cached = instant(from: cachedSignedAt) else { return .accept }
        guard let candidate = instant(from: candidateSignedAt) else { return .rejectUndatable }
        return candidate >= cached ? .accept : .rejectOlder
    }
}
