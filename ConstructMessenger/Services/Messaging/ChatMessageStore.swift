//
//  ChatMessageStore.swift
//  Construct Messenger
//

import Foundation
import CoreData

/// Who asked for an older batch. Recorded because the two callers are not equivalent and the
/// difference is invisible in a log otherwise — see `loadMoreMessages(trigger:)` and TODO 34.
enum LoadMoreTrigger: String {
    /// Explicit request (tests, any future manual control). Always honored by the store.
    case user
    /// Infinite-scroll sentinel / near-top geometry. View layer gates via
    /// `ChatScrollManager.shouldLoadOlderHistory` so entry-time LazyVStack top materialisation
    /// does not widen the window; residual hits of the counter mean a real near-top or contentFits fill.
    case indicatorAppeared
}

@MainActor
final class ChatMessageStore: NSObject {

    // MARK: - Dependencies

    private let chat: Chat
    private let viewContext: NSManagedObjectContext
    private let persistenceService = MessagePersistenceService()
    private weak var viewModel: ChatViewModel?

    // MARK: - FRC state

    private var fetchedResultsController: NSFetchedResultsController<Message>?
    private var frcDebounceTask: Task<Void, Never>?
    /// Serial generation so only the latest scheduled apply runs (debounce races).
    private var frcApplyGeneration: UInt64 = 0
    /// The one piece of state that defines what the transcript shows: everything from this instant
    /// forward. `loadMoreMessages` widens it and nothing else touches it.
    ///
    /// The visible list is a **function of this window**, re-derived from Core Data on every
    /// snapshot — never an accumulator. It used to be one: `applyFRCSnapshot` built the historic
    /// half by filtering `viewModel.messages` (the list) against the FRC's current contents, so the
    /// list was its own and only source of history. Two consequences, both seen in the 2026-08-05
    /// run: anything the validity filter dropped was gone permanently, because there was nowhere to
    /// re-read it from (`51 recent + 14 historic = 65` → `36 recent + 20 historic = 56`, nine
    /// messages simply absent); and `historic + fetched` was an unsorted concatenation resting on
    /// "everything not in the FRC window is older than everything in it", which the FRC does not
    /// guarantee — its `fetchLimit` is not re-applied on incremental updates, so `fetchedObjects`
    /// drifts (51/52/36 inside one second in that same log). See TODO 34.
    private var oldestLoadedTimestamp: Date?
    /// Last published transcript fingerprint — skip no-op FRC storms (status-spam / receipt).
    private var lastSnapshotFingerprint: UInt64 = 0

    private let initialMessageLimit = 30
    private let loadMoreBatchSize = 20
    /// Coalesce Core Data save bursts (send → sent → delivered → peer echo).
    private let frcDebounceMilliseconds: UInt64 = 120

    /// Coarse Core Data pre-filter. Note: messages are encrypted at rest
    /// (`decryptedContent == nil`), so the `BEGINSWITH` clauses only catch legacy
    /// unencrypted rows. The authoritative guard is `contentTypeRaw == 0` (stamped at
    /// save time by `applyStoredEncryption`) plus the in-Swift `isControlArtifact` /
    /// `isServiceArtifact` filter applied to fetched rows, which decrypts `displayText`.
    static let controlMessageFilterPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        NSPredicate(format: "contentTypeRaw == 0"),
        NSPredicate(format: "NOT (decryptedContent BEGINSWITH '__session_ready')"),
        NSPredicate(format: "NOT (decryptedContent BEGINSWITH 'session_ready_')"),
        NSPredicate(format: "NOT (decryptedContent BEGINSWITH '__session_ping')"),
        NSPredicate(format: "NOT (decryptedContent BEGINSWITH '__END_SESSION')"),
        NSPredicate(format: "NOT (decryptedContent BEGINSWITH '__binary_init_')")
    ])

    /// In-Swift backstop for rows the Core Data predicate cannot see through at-rest
    /// encryption. Drops any control/service payload that leaked into the transcript.
    private static func visible(_ messages: [Message]) -> [Message] {
        messages.filter { !$0.isControlArtifact && !$0.isServiceArtifact }
    }

    // MARK: - The transcript window

    /// Re-read the visible transcript for the current window, oldest-first.
    ///
    /// One fetch, one sort, one source. Duplicate ids are impossible by construction — which
    /// matters beyond tidiness: a `ForEach` fed duplicate ids renders unpredictably, and the merge
    /// this replaces could produce them whenever the FRC window slid under it.
    ///
    /// Sorted by `(timestamp, id)`: the id is not decoration. Messages sent in the same burst share
    /// a timestamp to the millisecond, and without a tie-break their relative order flips between
    /// fetches — which is a transcript that reshuffles itself while the user is looking at it.
    private func fetchWindow() -> [Message] {
        let request = Message.fetchRequest()
        var predicates: [NSPredicate] = [
            NSPredicate(format: "chat == %@", chat),
            ChatMessageStore.controlMessageFilterPredicate
        ]
        if let oldest = oldestLoadedTimestamp {
            predicates.append(NSPredicate(format: "timestamp >= %@", oldest as NSDate))
        } else {
            // No window yet (setup failed, or an empty chat): fall back to the newest page rather
            // than fetching the entire history.
            request.fetchLimit = initialMessageLimit
            request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            let newest = ChatMessageStore.visible((try? viewContext.fetch(request)) ?? [])
            return Array(newest.reversed())
        }
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        request.sortDescriptors = [
            NSSortDescriptor(key: "timestamp", ascending: true),
            NSSortDescriptor(key: "id", ascending: true)
        ]
        return ChatMessageStore.visible((try? viewContext.fetch(request)) ?? [])
    }

    /// Publish `window` if it differs from what is on screen. Returns whether it was published.
    @discardableResult
    private func publish(_ window: [Message]) -> Bool {
        guard let vm = viewModel else { return false }
        let fp = Self.fingerprint(window)
        guard fp != lastSnapshotFingerprint else { return false }
        lastSnapshotFingerprint = fp
        vm.messages = window
        return true
    }

    // MARK: - Init

    init(chat: Chat, viewContext: NSManagedObjectContext) {
        self.chat = chat
        self.viewContext = viewContext
    }

    func setViewModel(_ vm: ChatViewModel) {
        self.viewModel = vm
    }

    // MARK: - Setup

    func setup() {
        let fetchRequest = Message.fetchRequest()
        let chatPredicate = NSPredicate(format: "chat == %@", chat)
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            chatPredicate,
            ChatMessageStore.controlMessageFilterPredicate
        ])
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        fetchRequest.fetchLimit = initialMessageLimit
        fetchedResultsController = NSFetchedResultsController(
            fetchRequest: fetchRequest,
            managedObjectContext: viewContext,
            sectionNameKeyPath: nil,
            cacheName: nil
        )
        fetchedResultsController?.delegate = self
        do {
            try fetchedResultsController?.performFetch()
            // The FRC exists to *notify*, not to supply the list. Its first fetch does define the
            // initial window, though: the newest page.
            let fetched = ChatMessageStore.visible(fetchedResultsController?.fetchedObjects ?? [])
            oldestLoadedTimestamp = fetched.last?.timestamp   // sorted newest-first
            let window = fetchWindow()
            publish(window)
            Log.debug("FRC initial fetch: \(window.count) messages (oldest-first)", category: "ChatViewModel")
        } catch {
            Log.error("FRC fetch failed: \(error)", category: "ChatViewModel")
        }
    }

    // MARK: - Load more

    /// `trigger` says who asked. The store always widens when called; the view is responsible for
    /// not calling `.indicatorAppeared` during opening or while following the bottom (see
    /// `ChatScrollManager.shouldLoadOlderHistory`). The metric below is the residual gauge — entry
    /// used to fire it on every chat open (30 → 50); after the gate it should only tick on a real
    /// near-top scroll or a short-window fill.
    func loadMoreMessages(trigger: LoadMoreTrigger = .user) {
        guard let vm = viewModel else { return }
        guard !vm.isLoadingMore, vm.hasMoreMessages, let oldestTimestamp = oldestLoadedTimestamp else { return }
        vm.isLoadingMore = true
        Log.debug("Loading more messages before \(oldestTimestamp) [trigger=\(trigger.rawValue)]", category: "ChatViewModel")
        if trigger == .indicatorAppeared {
            PerformanceMetrics.shared.record(.loadMoreUnprompted, label: String(vm.messages.count))
        }
        defer { vm.isLoadingMore = false }

        // Fetch the next older batch only to learn where the widened window starts — the batch
        // itself is not spliced into the list. Newest-first so the last element is the oldest we
        // are admitting.
        let fetchRequest = Message.fetchRequest()
        let chatPredicate = NSPredicate(format: "chat == %@ AND timestamp < %@", chat, oldestTimestamp as NSDate)
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            chatPredicate,
            ChatMessageStore.controlMessageFilterPredicate
        ])
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        fetchRequest.fetchLimit = loadMoreBatchSize
        guard let older = try? viewContext.fetch(fetchRequest) else {
            Log.error("Failed to fetch more messages", category: "ChatViewModel")
            return
        }
        guard let newBound = older.last?.timestamp else {
            vm.hasMoreMessages = false
            Log.debug("No more older messages to load", category: "ChatViewModel")
            return
        }

        // Widening by timestamp, not by object identity, is what keeps a boundary shared by several
        // messages of the same millisecond from being split across two pages.
        let previousCount = vm.messages.count
        oldestLoadedTimestamp = newBound
        publish(fetchWindow())
        checkIfHasMoreMessages()
        Log.debug("Loaded \(vm.messages.count - previousCount) more messages (total: \(vm.messages.count))", category: "ChatViewModel")
    }

    private func checkIfHasMoreMessages() {
        guard let oldestTimestamp = oldestLoadedTimestamp else {
            viewModel?.hasMoreMessages = false
            return
        }
        let fetchRequest = Message.fetchRequest()
        let chatPredicate = NSPredicate(format: "chat == %@ AND timestamp < %@", chat, oldestTimestamp as NSDate)
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            chatPredicate,
            ChatMessageStore.controlMessageFilterPredicate
        ])
        fetchRequest.fetchLimit = 1
        viewModel?.hasMoreMessages = (try? viewContext.fetch(fetchRequest).first) != nil
    }

    // MARK: - Delete

    func deleteMessage(_ message: Message) {
        do {
            try persistenceService.deleteMessage(message, chat: chat, in: viewContext)
        } catch {
            Log.error("Failed to delete message: \(error)", category: "ChatViewModel")
        }
    }

    func deleteMessages(withIds messageIds: Set<String>) {
        do {
            try persistenceService.deleteMessages(withIds: messageIds, chat: chat, in: viewContext)
        } catch {
            Log.error("Failed to delete messages: \(error)", category: "ChatViewModel")
        }
    }

    // MARK: - FRC snapshot

    @MainActor
    private func applyFRCSnapshot(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        guard let vm = viewModel else { return }
        guard !chat.isDeleted, chat.managedObjectContext != nil else {
            vm.messages = []
            lastSnapshotFingerprint = 0
            return
        }
        // `controller` is deliberately unread: the FRC is the change *trigger*, and reading the
        // transcript off `fetchedObjects` is what this method used to do wrong. Its `fetchLimit`
        // is not re-applied on incremental updates, so its contents drift under us.
        _ = controller

        // Re-derive rather than merge. `publish` skips identical transcripts — the FRC fires on
        // every receipt and status write, and reassigning `messages` forces LazyVStack identity
        // churn and black flashes.
        let window = fetchWindow()
        guard publish(window) else { return }
        Log.debug("FRC updated: \(window.count) message(s) in window", category: "ChatViewModel")
    }

    /// Cheap structural fingerprint: ordered ids + delivery status + edit flag.
    /// Ignores pure fault refreshes that don't change what the user sees.
    private static func fingerprint(_ messages: [Message]) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(messages.count)
        for msg in messages {
            hasher.combine(msg.id)
            hasher.combine(msg.deliveryStatusRaw)
            hasher.combine(msg.isEdited)
            hasher.combine(msg.timestamp.timeIntervalSince1970)
            // Transcript / display can land after STT without changing delivery status.
            hasher.combine(msg.transcriptText as String?)
        }
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    /// Schedule a coalesced snapshot apply. Cancels prior debounce so only the last
    /// FRC burst in a ~120ms window publishes to the UI.
    private func scheduleFRCApply(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        frcDebounceTask?.cancel()
        frcApplyGeneration &+= 1
        let generation = frcApplyGeneration
        frcDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(self?.frcDebounceMilliseconds ?? 120))
            guard !Task.isCancelled, let self else { return }
            guard generation == self.frcApplyGeneration else { return }
            self.applyFRCSnapshot(controller)
        }
    }
}

// MARK: - NSFetchedResultsControllerDelegate

extension ChatMessageStore: NSFetchedResultsControllerDelegate {
    nonisolated func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        // Hop to MainActor once — don't nest Task-in-Task races that each schedule a debounce.
        Task { @MainActor [weak self] in
            self?.scheduleFRCApply(controller)
        }
    }
}
