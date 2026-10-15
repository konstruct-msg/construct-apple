//
//  PlaybackSource.swift
//  Construct Messenger
//
//  A track keeps playing when its chat is left; the now-playing banner is what still controls it
//  there. It needs to know which message the track is, and which chat is on screen — the banner
//  stays out of the chat the track came from, where the message's own row is the control.
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

    /// The message to scroll to in `chatId`, once.
    func takeFocus(in chatId: String) -> String? {
        guard let focus, focus.chatId == chatId else { return nil }
        self.focus = nil
        return focus.messageId
    }

    // MARK: - The rule, pure

    /// The banner is up while a track it can name is loaded, except in that track's own chat.
    nonisolated static func showsBanner(for source: PlaybackSource?, onScreen chatId: String?) -> Bool {
        guard let source else { return false }
        return source.chatId != chatId
    }
}
