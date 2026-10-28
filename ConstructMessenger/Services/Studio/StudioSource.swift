//
//  StudioSource.swift
//  Construct Messenger
//
//  The application whose sound is Studio's program and whose windows are its screen — the DAW,
//  chosen by the host in the call window and kept per Mac. Until 2026-10-28 it was Reaper unless
//  set with `defaults write`, and with Reaper closed Studio ended a second after it started, with
//  nothing on screen to say why; the same key is kept, so a value set that way still holds.
//

import Foundation

struct StudioSource: Equatable, Hashable, Sendable {
    let bundleID: String
    let name: String

    static let defaultsKey = "StudioSourceBundleID"

    /// DAWs taken without asking when nothing was chosen yet, in this order. A prefix, where a
    /// maker puts the version into the id.
    static let knownDAWPrefixes = [
        "com.cockos.reaper",
        "com.apple.logic10",
        "com.ableton.live",
        "com.avid.ProTools",
        "com.bitwig.BitwigStudio",
        "com.presonus.studioone",
        "com.steinberg.cubase",
        "com.steinberg.nuendo",
        "com.image-line.flstudio",
        "com.apple.garageband10",
    ]

    static func stored(in defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: defaultsKey)
    }

    func store(in defaults: UserDefaults = .standard) {
        defaults.set(bundleID, forKey: Self.defaultsKey)
    }

    /// The source among the running applications: the one chosen before, else the first known DAW
    /// running. Nil when neither runs — Studio cannot start, and the window says so.
    static func pick(stored: String?, running: [StudioSource]) -> StudioSource? {
        if let stored, let chosen = running.first(where: { $0.bundleID == stored }) { return chosen }
        for prefix in knownDAWPrefixes {
            if let daw = running.first(where: { $0.bundleID.hasPrefix(prefix) }) { return daw }
        }
        return nil
    }
}

/// Whether Studio sends the DAW's windows besides its sound; kept per Mac, on until turned off.
enum StudioScreenChoice {
    static let defaultsKey = "StudioSendsScreen"

    static func stored(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }

    static func store(_ sends: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(sends, forKey: defaultsKey)
    }
}

/// What went wrong on the host after Studio started, for the call window. The technical detail is
/// in the log.
enum StudioProblem: Equatable, Sendable {
    /// The DAW's sound could not be taken: it quit, or has not played anything since it opened.
    case programNotCaptured
    /// The DAW's windows could not be taken: no screen-recording permission, or no window open.
    /// The studio goes on as sound.
    case screenNotCaptured
}
