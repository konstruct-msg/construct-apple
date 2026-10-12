//
//  TranscriptWindow.swift
//  Construct Messenger
//
//  An open chat's transcript, paged over `MessageStore` (local-store plan, lane C). It replaces
//  `ChatMessageStore`'s fetched-results controller: the store's change feed is the trigger, a
//  page is one read, and the rows are values (`TranscriptRow`).
//
//  The window is everything from its oldest row forward. Loading more moves that row back; nothing
//  else does. The list is re-read from the store on every change and never accumulated — the
//  reasons `ChatMessageStore` gave for that (TODO 34) hold here unchanged.
//

import Foundation
import Observation

/// Who asked for an older batch. Recorded because the two callers are not equivalent and the
/// difference is invisible in a log otherwise — see `ChatViewModel.loadMoreMessages(trigger:)` and TODO 34.
enum LoadMoreTrigger: String {
    /// Explicit request (tests, any future manual control). Always honored by the store.
    case user
    /// Infinite-scroll sentinel / near-top geometry. View layer gates via
    /// `ChatScrollManager.shouldLoadOlderHistory` so entry-time LazyVStack top materialisation
    /// does not widen the window; residual hits of the counter mean a real near-top or contentFits fill.
    case indicatorAppeared
}

@MainActor
@Observable
final class TranscriptWindow {

    /// Oldest first; only what a person reads — a control or service row is never one.
    ///
    /// Reassigned only when the set or the order of rows changes. A status, an edit or a body read
    /// late changes one entry's `row` and nothing else, so the list is not republished for it —
    /// on a long chat every republish was a visible flicker (`ChatMessageStore` measured four in
    /// one second for one incoming message, 2026-08-11), and a row draws itself again from its own
    /// entry (`ObservedTranscriptRow`).
    private(set) var entries: [TranscriptEntry] = []

    /// The rows, read once. Reading this observes every entry: for a caller outside a list's
    /// render — a test, playback, the gallery — never for the list itself.
    var rows: [TranscriptRow] { entries.map(\.row) }
    private(set) var hasMore = true
    private(set) var isLoadingMore = false

    @ObservationIgnored private let chatId: String
    @ObservationIgnored private let store: any MessageStore
    @ObservationIgnored private let debounce: Duration
    /// `(orderKey, id)` of the oldest row read — visible or not, so a hidden row at the edge does
    /// not move the window when the page is read again.
    @ObservationIgnored private var oldest: (orderKey: String, id: String)?
    /// How many writes the store reported for each row while the chat is open (`TranscriptRow.revision`).
    @ObservationIgnored private var revisions: [String: Int] = [:]
    @ObservationIgnored private var listening: Task<Void, Never>?
    @ObservationIgnored private var pending: Task<Void, Never>?

    static let firstPage = 30
    static let olderPage = 20
    /// More than any chat is read in one sitting; a bound, not a page.
    private static let windowCeiling = 10_000

    init(chatId: String, store: any MessageStore = LocalRepositories.messages, debounce: Duration = .milliseconds(120)) {
        self.chatId = chatId
        self.store = store
        self.debounce = debounce
    }

    isolated deinit {
        listening?.cancel()
        pending?.cancel()
    }

    /// The newest page, then every change the store reports. Subscribed before the first read, so
    /// a write between the two is not missed.
    func start() {
        guard listening == nil else { return }
        let changes = store.changes()
        listening = Task { [weak self] in
            for await ids in changes {
                guard let self else { return }
                self.changed(ids)
            }
        }
        readFirstPage()
    }

    func stop() {
        listening?.cancel()
        listening = nil
        pending?.cancel()
        pending = nil
    }

    /// The next older page joins the window.
    func loadMore() {
        guard !isLoadingMore, hasMore, let oldest else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let older = (try? store.messages(inChat: chatId, before: oldest, limit: Self.olderPage)) ?? []
        guard let first = older.first else {
            hasMore = false
            return
        }
        self.oldest = (first.orderKey, first.id)
        reread()
        hasMore = anythingBefore(first)
    }

    // MARK: - Reading

    /// Pages back from the newest until a page's worth is visible, or history ends: a run of
    /// hidden rows at the tip must not open the chat empty.
    private func readFirstPage() {
        var read: [MessageRecord] = []
        var before: (orderKey: String, id: String)?
        var reachedStart = false
        while Self.visible(read).count < Self.firstPage {
            let page = (try? store.messages(inChat: chatId, before: before, limit: Self.firstPage)) ?? []
            read = page + read
            guard let first = page.first, page.count == Self.firstPage else {
                reachedStart = true
                break
            }
            before = (first.orderKey, first.id)
        }
        oldest = read.first.map { ($0.orderKey, $0.id) }
        hasMore = !reachedStart && read.first.map(anythingBefore) ?? false
        publish(read)
    }

    private func reread() {
        guard let oldest else {
            readFirstPage()
            return
        }
        let read = (try? store.messages(inChat: chatId, from: oldest, limit: Self.windowCeiling)) ?? []
        publish(read)
    }

    private func anythingBefore(_ record: MessageRecord) -> Bool {
        !((try? store.messages(inChat: chatId, before: (record.orderKey, record.id), limit: 1)) ?? []).isEmpty
    }

    private func publish(_ read: [MessageRecord]) {
        let shown = Self.visible(read)
        // What was just decrypted is what the bubbles are about to ask for.
        for record in shown { MessageDisplayCache.shared.hold(record) }
        let next = shown.map { TranscriptRow($0, revision: revisions[$0.id, default: 0]) }
        let held = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var reshaped = next.map(\.id) != entries.map(\.id)
        let updated = next.map { row -> TranscriptEntry in
            guard let entry = held[row.id], entry.isSentByMe == row.isSentByMe,
                  entry.safeTimestamp == row.safeTimestamp else {
                // What grouping reads is fixed per entry; a row whose sender or time moved is a
                // new entry, and so a new list.
                reshaped = true
                return TranscriptEntry(row)
            }
            if entry.row != row { entry.row = row }
            return entry
        }
        if reshaped { entries = updated }
    }

    // MARK: - Changes

    private func changed(_ ids: Set<String>) {
        // The text needs no eviction here: the re-read below holds the fresh body, and a deleted
        // message's is dropped by the store that deleted it.
        for id in ids { revisions[id, default: 0] += 1 }
        pending?.cancel()
        pending = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            self.reread()
        }
    }

    // MARK: - What is never a bubble

    /// The transcript's rows: regular content that is neither a leaked control signal nor a text
    /// delivery receipt from an old build. The managed rows were filtered by `contentTypeRaw == 0`
    /// in the fetch and by `isControlArtifact` / `isServiceArtifact` after it — the same tests.
    static func visible(_ records: [MessageRecord]) -> [MessageRecord] {
        records.filter { record in
            guard record.contentType == .regular else { return false }
            let text = LocalMessagePayload.decode(record.body).displayString
            return !MessageContentType.isControlPayload(text) && !MessageContentType.isLegacyDeliveryReceipt(text)
        }
    }
}

/// One transcript row, observed on its own. What grouping reads of it — who sent it and when —
/// never changes for an entry; everything else lives in `row`.
@MainActor
@Observable
final class TranscriptEntry: Identifiable, TranscriptGroupable {
    let id: String
    let isSentByMe: Bool
    let safeTimestamp: Date
    var row: TranscriptRow

    init(_ row: TranscriptRow) {
        id = row.id
        isSentByMe = row.isSentByMe
        safeTimestamp = row.safeTimestamp
        self.row = row
    }
}
