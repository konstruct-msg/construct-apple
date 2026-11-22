//
//  ChatMediaGalleryModel.swift
//  Construct Messenger
//
//  A chat's media, page by page, from the store's media index (construct-docs todo 327,
//  decisions/chat-media-gallery-storage-backup.md): pictures and videos as a grid, files as a list.
//

import Foundation
import Observation

/// What a tab of the gallery shows.
enum ChatMediaTab: String, CaseIterable, Identifiable, Sendable {
    /// Photos, videos and animations — the grid.
    case visual
    /// Documents and audio files — the list, one row per message.
    case files

    var id: String { rawValue }

    /// The index kinds the tab asks for. Voice notes and round videos have a tab of their own
    /// later; they are not pictures to page through.
    var kinds: [LocalMediaKind] {
        switch self {
        case .visual: return [.photo, .video, .animation]
        case .files: return [.file]
        }
    }
}

@Observable
@MainActor
final class ChatMediaGalleryModel {
    let chatId: String
    private(set) var tab: ChatMediaTab
    /// What is loaded of the tab, newest first.
    private(set) var items: [ChatMediaItem] = []
    /// No page left: the last one came back short.
    private(set) var isComplete = false

    @ObservationIgnored private let store: any MessageStore
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private var rows: [String: TranscriptRow] = [:]

    init(chatId: String, tab: ChatMediaTab = .visual, store: any MessageStore = LocalRepositories.messages, pageSize: Int = 90) {
        self.chatId = chatId
        self.tab = tab
        self.store = store
        self.pageSize = max(1, pageSize)
    }

    /// Another tab: what was loaded is dropped and its first page read.
    func select(_ tab: ChatMediaTab) {
        guard tab != self.tab else { return }
        self.tab = tab
        items = []
        isComplete = false
        loadMore()
    }

    /// The next page of the tab, after the last item held.
    func loadMore() {
        guard !isComplete else { return }
        let page: [ChatMediaItem]
        do {
            page = try store.media(inChat: chatId, kinds: tab.kinds, before: items.last, limit: pageSize)
        } catch {
            Log.error("ChatMediaGallery: a page did not load — \(error)", category: "Storage")
            isComplete = true
            return
        }
        items.append(contentsOf: page)
        if page.count < pageSize { isComplete = true }
    }

    /// Called as `item` appears: the next page once the grid nears the end of what is held.
    func loadMoreIfNeeded(after item: ChatMediaItem) {
        guard !isComplete, let index = items.firstIndex(of: item) else { return }
        if index >= items.count - Self.prefetchDistance { loadMore() }
    }

    static let prefetchDistance = 12

    /// The messages the items belong to, each once, newest first: the files tab is a row per
    /// message, since a message of three files is one bubble.
    var messageIds: [String] {
        var seen = Set<String>()
        return items.compactMap { seen.insert($0.messageId).inserted ? $0.messageId : nil }
    }

    /// The message `messageId` as the transcript draws it; nil when it is gone.
    func row(_ messageId: String) -> TranscriptRow? {
        if let row = rows[messageId] { return row }
        guard let record = try? store.message(messageId) else { return nil }
        let row = TranscriptRow(record, revision: 0)
        rows[messageId] = row
        return row
    }

    /// The loaded messages oldest first — the order the full-screen viewer pages through, as it
    /// does in the chat.
    var rowsOldestFirst: [TranscriptRow] {
        messageIds.reversed().compactMap(row)
    }
}
