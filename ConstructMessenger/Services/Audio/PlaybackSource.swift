//
//  PlaybackSource.swift
//  Construct Messenger
//
//  A track keeps playing when its chat is left; the now-playing banner is what still controls it
//  there. It needs to know which message the track is, and which chat is on screen — a tap in
//  the track's own chat scrolls to the message instead of opening the chat again.
//

import Foundation
import Observation

/// The message a loaded track belongs to.
struct PlaybackSource: Equatable, Sendable {
    let chatId: String
    let messageId: String
    /// A music file's name; nil for a voice message.
    var fileName: String? = nil
}

@MainActor
@Observable
final class ChatOnScreen {

    static let shared = ChatOnScreen()

    /// The chat whose transcript is on screen; nil on every other screen.
    private(set) var chatId: String?

    /// A message to bring into view once its chat has opened — the banner's way back to it.
    @ObservationIgnored private var focus: PlaybackSource?

    func appeared(_ chatId: String) { self.chatId = chatId }

    /// Only the chat that appeared clears it: a push shows the next chat before the last one
    /// has gone.
    func disappeared(_ chatId: String) {
        if self.chatId == chatId { self.chatId = nil }
    }

    func requestFocus(_ source: PlaybackSource) { focus = source }

    /// A message to bring into view in the chat already on screen: the banner tapped there.
    private(set) var jump: PlaybackSource?

    func requestJump(_ source: PlaybackSource) { jump = source }

    /// The message to scroll to in `chatId`, once.
    func takeJump(in chatId: String) -> String? {
        guard let jump, jump.chatId == chatId else { return nil }
        self.jump = nil
        return jump.messageId
    }

    /// The message to scroll to in `chatId`, once.
    func takeFocus(in chatId: String) -> String? {
        guard let focus, focus.chatId == chatId else { return nil }
        self.focus = nil
        return focus.messageId
    }

    // MARK: - The rule, pure

    enum BannerTap: Equatable { case openChat, scrollInPlace }

    /// The banner is up on every screen while a track is loaded, its own chat too: scrolled back
    /// through history, the message's row is long off screen (owner, 2026-10-17). There a tap
    /// scrolls to the message; anywhere else it opens the chat at it.
    nonisolated static func bannerTap(for source: PlaybackSource, onScreen chatId: String?) -> BannerTap {
        source.chatId == chatId ? .scrollInPlace : .openChat
    }
}
