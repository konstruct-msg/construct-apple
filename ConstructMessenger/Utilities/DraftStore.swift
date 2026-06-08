//
//  DraftStore.swift
//  Construct Messenger
//
//  Holds unsent message drafts so they survive leaving and re-entering a chat.
//  ChatView's `messageText` is `@State` and the ChatViewModel is created per
//  navigation push — both are destroyed when the chat is popped off the nav
//  stack, which is why a half-typed message used to vanish on the way back.
//
//  Storage is intentionally IN-MEMORY only: drafts are plaintext message
//  content, and writing them to UserDefaults/disk would leak that plaintext at
//  rest, which contradicts the privacy-first model. Drafts therefore survive
//  navigation within a running session but are gone after the app is killed.
//  If durable drafts are ever wanted, back this with the encrypted store, not
//  UserDefaults.
//

import Foundation

@MainActor
final class DraftStore {
    static let shared = DraftStore()
    private init() {}

    /// Keyed by `Chat.id` (stable per conversation).
    private var drafts: [String: String] = [:]

    /// The saved draft for a chat, or "" if none.
    func draft(for chatId: String) -> String {
        drafts[chatId] ?? ""
    }

    /// Persist (or clear, when `text` is blank) the draft for a chat.
    func save(_ text: String, for chatId: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            drafts.removeValue(forKey: chatId)
        } else {
            drafts[chatId] = text
        }
    }

    /// Drop the draft for a chat (e.g. after a successful send).
    func clear(for chatId: String) {
        drafts.removeValue(forKey: chatId)
    }
}
