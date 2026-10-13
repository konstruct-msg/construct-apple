//
//  ForwardPickerView.swift
//  Construct Messenger
//
//  Choosing where a forward goes. The picked chat opens and sends the content itself — through
//  its own send path, with its own session — so a forward needs no second sender beside the one
//  every chat already has (`ForwardDrafts`).
//

import SwiftUI

/// Content waiting for its destination chat to open. The chat takes it when it appears, or at
/// once if it is already the one on screen.
@MainActor
@Observable
final class ForwardDrafts {
    static let shared = ForwardDrafts()

    private(set) var pending: [String: [ForwardItem]] = [:]

    func hand(_ items: [ForwardItem], to chatId: String) {
        guard !items.isEmpty else { return }
        pending[chatId, default: []].append(contentsOf: items)
    }

    func take(for chatId: String) -> [ForwardItem] {
        pending.removeValue(forKey: chatId) ?? []
    }
}

struct ForwardPickerView: View {
    let onPick: (ChatRecord) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var chats: [ChatRecord] {
        let all = ChatsLive.shared.chats()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        return all.filter { ChatsLive.matches($0, query: trimmed) }
    }

    var body: some View {
        List(chats) { chat in
            Button {
                onPick(chat)
                dismiss()
            } label: {
                ChatRowView(chat: chat)
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.CT.bg)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .ctBackground()
        .searchable(text: $query, prompt: LocalizedStringKey("search_prompt"))
        .navigationTitle(NSLocalizedString("forward_to", comment: ""))
        .overlay {
            if chats.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }
}
