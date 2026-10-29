//
//  StudioTalkback.swift
//  Construct Messenger
//
//  Whether the call's microphone is open while Studio is on (`decisions/studio-mode-on-desktop.md`,
//  open question 4). Two ways, the person's choice (owner, 2026-10-28):
//  - hold to talk, the default: a microphone near monitors sends the mix back a second time,
//    through the voice path, some 0.3 s apart from the program, and the echo canceller of the call
//    does not know the program to remove it;
//  - always on, for engineers in headphones, who should not have to press anything to talk.
//  The person's own mute wins in both. Outside Studio the microphone is the call's, as before.
//

import Foundation

enum StudioTalkbackMode: String, CaseIterable, Sendable {
    case holdToTalk
    case alwaysOn

    static let defaultsKey = "StudioTalkbackMode"

    /// The last choice on this Mac; hold to talk until one is made.
    static func stored(in defaults: UserDefaults = .standard) -> StudioTalkbackMode {
        defaults.string(forKey: defaultsKey).flatMap(StudioTalkbackMode.init(rawValue:)) ?? .holdToTalk
    }

    func store(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

struct StudioTalkback: Equatable, Sendable {
    var mode: StudioTalkbackMode
    /// The talk key or button is held down.
    var held = false

    func microphoneOpen(muted: Bool, studioOn: Bool) -> Bool {
        if muted { return false }
        guard studioOn else { return true }
        return mode == .alwaysOn || held
    }
}
