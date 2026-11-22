//
//  MediaAutoDownloadPolicy.swift
//  Construct Messenger
//
//  Whether to fetch a received attachment now, or wait until the user looks at it.
//
//  Waiting used to be the only behaviour: the bubble downloaded on `onAppear`. That is fine for
//  bandwidth and wrong for durability — the server drops an uploaded object 7 days after upload
//  (see MediaEvictionPolicy), so a chat left unopened for a week loses its photos permanently. The
//  bubble then shows a placeholder for something that existed and was addressed to the user.
//
//  So: fetch on arrival is available, subject to a setting, because on the networks this app is
//  built for bandwidth is not free and 4 MB per photo is a real cost.
//
//  The default is `.never` (owner, 2026-11-22, vault todo 134; decisions/media-fetch-on-arrival).
//  A download carries no token but comes over the stream's own connection, so a fetch moments
//  after delivery lets the server tie "this object, uploaded by A" to "the device it was just
//  delivered to" — the link sealed sender hides. Off by default, the download happens when the
//  person opens the chat; the seven-day loss returns for a chat left unopened, and the footer in
//  Data & storage says so. Turned on, the fetch waits a random `prefetchDelay` first.
//

import Foundation

enum MediaAutoDownloadSetting: Int, CaseIterable {
    /// Never fetch ahead; media arrives when the user opens the chat, as it did before 2026-08-11.
    /// Honest about its cost: a chat not opened within the server's retention window loses media.
    case never = 0
    /// Wi-Fi and wired only — nothing on cellular, nothing in Low Data Mode.
    case unmetered = 1
    /// Any connection.
    case always = 2

    /// Until 2026-11-22 `.unmetered`. An install that never chose follows the new default; one
    /// that chose keeps its choice (`current` reads the stored value first).
    static let `default`: MediaAutoDownloadSetting = .never

    /// UserDefaults key. Read through `MediaAutoDownloadPolicy.current` rather than directly, so
    /// the "no value stored yet" case resolves to `.default` in one place.
    static let defaultsKey = "media.autoDownload"
}

enum MediaAutoDownloadPolicy {

    /// Above this, an attachment waits for the user regardless of the setting — except on
    /// `.always`, where the user has said to fetch anyway.
    ///
    /// Videos are the reason. A photo is bounded by MediaOptimizer at 4 MB; a transcoded clip is
    /// not, and silently pulling tens of megabytes because a message arrived is not something a
    /// person asked for by leaving auto-download on Wi-Fi at its default.
    static let unmeteredSizeCeiling: Int64 = 16 * 1024 * 1024

    /// How long an arrival prefetch waits before it starts, drawn uniformly per album: 2–30 s.
    ///
    /// The server delivers a message to this device at T over the same connection the download
    /// then comes in on; a fetch at T + 50 ms ties the object to that delivery exactly. A random
    /// wait mixes it with the other deliveries of the half-minute — it weakens the timing link and
    /// does not remove it (the connection is the same). Short enough that a photo in an open chat
    /// is not held up noticeably; a tap or the bubble on screen downloads without waiting. Signal
    /// fetches at once (`AttachmentDownloadJob.kt`: no delay, only network constraints).
    static let prefetchDelayMilliseconds: ClosedRange<Int64> = 2_000...30_000

    static func prefetchDelay<G: RandomNumberGenerator>(using generator: inout G) -> Duration {
        .milliseconds(Int64.random(in: prefetchDelayMilliseconds, using: &generator))
    }

    static func prefetchDelay() -> Duration {
        var generator = SystemRandomNumberGenerator()
        return prefetchDelay(using: &generator)
    }

    /// The setting as stored, falling back to the default when nothing has been chosen.
    static func current(defaults: UserDefaults = .standard) -> MediaAutoDownloadSetting {
        guard let raw = defaults.object(forKey: MediaAutoDownloadSetting.defaultsKey) as? Int,
              let setting = MediaAutoDownloadSetting(rawValue: raw) else {
            return .default
        }
        return setting
    }

    /// Whether to fetch an attachment of `sizeBytes` the moment its message arrives.
    ///
    /// `isExpensive` is cellular or a personal hotspot; `isConstrained` is Low Data Mode. Low Data
    /// Mode is treated as metered even on Wi-Fi: the user has told the system to hold back on
    /// exactly this kind of speculative transfer, and overriding that because the connection
    /// happens to be Wi-Fi would be ignoring an explicit instruction.
    static func shouldFetchOnArrival(
        setting: MediaAutoDownloadSetting,
        sizeBytes: Int64,
        isExpensive: Bool,
        isConstrained: Bool,
        sizeCeiling: Int64 = unmeteredSizeCeiling
    ) -> Bool {
        switch setting {
        case .never:
            return false
        case .always:
            return true
        case .unmetered:
            guard !isExpensive, !isConstrained else { return false }
            return sizeBytes <= sizeCeiling
        }
    }
}
