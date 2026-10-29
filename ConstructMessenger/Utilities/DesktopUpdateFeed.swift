//
//  DesktopUpdateFeed.swift
//  Construct Messenger
//
//  Where Konstruct Desktop asks for updates. One feed per architecture: the DMGs are thin (an
//  arm64 build and an x86_64 build, not one universal file twice the size), so an Intel Mac
//  must never be offered the arm64 DMG. The feeds are assets of one fixed GitHub release,
//  replaced on every build (`scripts/build_desktop_dmg.sh --publish`); the server learns
//  nothing about updates.
//
//  Pure, and in the shared folder so the iOS test target can test it; only Desktop calls it.
//

import Foundation

enum DesktopUpdateFeed {
    enum Arch: String {
        case arm64
        case x86_64
    }

    /// The release that carries the feeds. Its tag never changes; its assets do. The repository
    /// was construct-ios until 2026-10-29; 0.3.21 still asks there and GitHub redirects it, so
    /// no repository may ever take that name again.
    static let feedRelease = "https://github.com/konstruct-msg/construct-apple/releases/download/desktop-beta-feed"

    static func url(for arch: Arch) -> URL {
        URL(string: "\(feedRelease)/appcast-\(arch.rawValue).xml")!
    }

    /// The architecture this binary was built for.
    static var current: Arch {
        #if arch(x86_64)
        return .x86_64
        #else
        return .arm64
        #endif
    }

    /// `KonstructUpdatesEnabled` from Info.plist: `YES` only in the configurations that ship
    /// through the feed. A missing or unexpanded value is off — a build that does not know its
    /// channel must not replace itself.
    static func isEnabled(infoValue: Any?) -> Bool {
        (infoValue as? String) == "YES"
    }
}
