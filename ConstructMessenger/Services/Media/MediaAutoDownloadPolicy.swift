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
//  So: fetch on arrival, subject to a setting, because on the networks this app is built for
//  bandwidth is not free and 4 MB per photo is a real cost.
//
//  The default is `.unmetered`, and that is a strict improvement rather than a trade: on cellular
//  it behaves exactly as before (nothing is fetched until the bubble appears), and on Wi-Fi it
//  closes the seven-day hole. Choosing `.always` is the user saying they would rather spend the
//  bytes than lose the picture.
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

    static let `default`: MediaAutoDownloadSetting = .unmetered

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
