//
//  ReadSync.swift
//  Construct Messenger
//
//  How far this account has read each chat, kept in step across its own devices (TODO 152,
//  construct-docs decisions/read-state-syncs-between-own-devices.md, owner 2026-10-15). Until then
//  "read" was a counter on the device that read: the Desktop started after a day showed every chat
//  the phone had read and answered as unread.
//
//  Only between our own devices, and only when there is more than one: a contact never gets this —
//  it gets the delivery receipt (14), as before. The marker travels as CONTENT_TYPE_READ_SYNC (30)
//  inside the ciphertext, in an envelope that says SENDER_SYNC (23) outside like every copy to an
//  own device, at most every two minutes with jitter and when the app leaves the screen.
//

import Foundation
import SwiftProtobuf
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum ReadSync {

    /// A read boundary: the last read incoming message, by what every device of ours holds alike —
    /// its id from inside the ciphertext and its sender's time. Never a server position: each
    /// device's mailbox numbers its copy differently.
    struct Boundary: Codable, Equatable, Sendable {
        var sentAtMs: UInt64
        var messageId: String

        init(sentAtMs: UInt64, messageId: String) {
            self.sentAtMs = sentAtMs
            self.messageId = messageId.lowercased()
        }

        /// The boundary a stored message names. The sender's time is kept in whole seconds, the
        /// same on every device, so the milliseconds agree too.
        init(of message: MessageRecord) {
            self.init(
                sentAtMs: UInt64(max(0, message.timestamp.timeIntervalSince1970 * 1000)),
                messageId: message.id
            )
        }

        init(_ core: ReadBoundary) {
            self.init(sentAtMs: core.sentAtMs, messageId: core.messageId)
        }

        var core: ReadBoundary { ReadBoundary(sentAtMs: sentAtMs, messageId: messageId) }
    }

    enum Outcome: Equatable { case apply, ignore, drop }

    // MARK: - The rule (the core's: construct-rules `read_sync`; vectors knst_read_markers.json)

    /// Strictly after, on (sent_at_ms, message_id), the id compared as bytes.
    static func isLater(_ a: Boundary, than b: Boundary) -> Bool {
        readBoundaryIsLater(a: a.core, b: b.core)
    }

    /// An incoming message is read when it is at or before the boundary.
    static func covers(_ boundary: Boundary, _ message: Boundary) -> Bool {
        readBoundaryCovers(boundary: boundary.core, message: message.core)
    }

    /// What a received marker does — the core's answer for a boundary `held`. One not from our own
    /// account is dropped, whatever it says.
    static func outcome(of marker: Boundary, held: Boundary?, fromOwnAccount: Bool) -> Outcome {
        let state = ReadMarkerState()
        if let held { _ = state.advance(partner: "p", to: held.core) }
        return Outcome(state.applyMarker(partner: "p", marker: marker.core, fromOwnAccount: fromOwnAccount, ownAccount: ""))
    }

    // MARK: - Payload

    static func encode(_ markers: [String: Boundary]) -> Data? {
        var payload = Shared_Proto_Core_V1_ReadMarkers()
        payload.markers = markers.sorted { $0.key < $1.key }.map { partner, boundary in
            var marker = Shared_Proto_Core_V1_ReadMarker()
            marker.partnerUserID = partner
            marker.lastReadMessageID = boundary.messageId
            marker.lastReadSentAtMs = boundary.sentAtMs
            return marker
        }
        return try? payload.serializedData()
    }

    static func decode(_ data: Data) -> [(partner: String, boundary: Boundary)]? {
        guard let payload = try? Shared_Proto_Core_V1_ReadMarkers(serializedBytes: data) else { return nil }
        return payload.markers.compactMap { marker in
            guard !marker.partnerUserID.isEmpty, !marker.lastReadMessageID.isEmpty else { return nil }
            return (marker.partnerUserID.lowercased(),
                    Boundary(sentAtMs: marker.lastReadSentAtMs, messageId: marker.lastReadMessageID))
        }
    }

    // MARK: - Unread

    /// How many of the chat's unread messages a boundary leaves unread — the core's count
    /// (`read_unread_left`): by the position of the boundary's message in the chat, by time when
    /// it is not there (owner, 2026-11-12, as Android). Reads the newest messages only.
    static func unreadLeft(
        inChat chatId: String, unread: Int, boundary: Boundary, messages: any MessageStore
    ) -> Int {
        guard unread > 0 else { return 0 }
        // Outgoing messages sit between the incoming ones; a margin keeps them from crowding the
        // window out.
        let window = (try? messages.messages(inChat: chatId, before: nil, limit: unread * 2 + 50)) ?? []
        let incoming = window.filter { !$0.isSentByMe }.map {
            ReadIncoming(messageId: $0.id, atMs: Boundary(of: $0).sentAtMs)
        }
        return Int(readUnreadLeft(unread: UInt32(unread), incoming: incoming, boundary: boundary.core))
    }
}

private extension ReadSync.Outcome {
    init(_ core: ReadMarkerOutcome) {
        switch core {
        case .apply: self = .apply
        case .ignore: self = .ignore
        case .drop: self = .drop
        }
    }
}

// MARK: - Boundaries held

/// The read boundary per partner (`ServerUserId`, lowercased) this device holds — moved by reading
/// here and by markers from our other devices — and the markers not yet sent to them. The core's
/// state (`ReadMarkerState`), kept as its CFE. Read from the receive path on any thread.
final class ReadBoundaries: @unchecked Sendable {

    static let shared = ReadBoundaries()

    /// Through the store's key-value pairs, so it goes with the account's store. The core's CFE.
    static let key = "construct.readBoundaries.v2"
    /// v1 kept the boundaries as JSON. Read once into the core's state, until `legacyJSONUntil`.
    static let legacyKey = "construct.readBoundaries.v1"
    /// 2027-01-31: after it `load` stops reading v1 (rule 11); `ReadSyncTests` fails on that day.
    static let legacyJSONUntil = Date(timeIntervalSince1970: 1_801_353_600)

    private let store: () -> any KeyValueStore
    private let lock = NSLock()
    private var held: ReadMarkerState?

    init(store: (() -> any KeyValueStore)? = nil) {
        self.store = store ?? { LocalRepositories.keyValue }
        NotificationCenter.default.addObserver(forName: .localStoreReplaced, object: nil, queue: nil) { [weak self] _ in
            self?.lock.withLock { self?.held = nil }
        }
    }

    /// Boundaries over a store of their own — a test's.
    static func isolated() -> ReadBoundaries {
        let suite = "construct.tests.readBoundaries.\(UUID().uuidString)"
        let store = DefaultsKeyValueStore(defaults: UserDefaults(suiteName: suite)!)
        return ReadBoundaries(store: { store })
    }

    func boundary(for partner: String) -> ReadSync.Boundary? {
        lock.withLock { load().boundary(partner: partner).map(ReadSync.Boundary.init) }
    }

    /// Moves the boundary if `boundary` is later; true when it moved.
    @discardableResult
    func advance(_ partner: String, to boundary: ReadSync.Boundary) -> Bool {
        changing { $0.advance(partner: partner, to: boundary.core) }
    }

    /// Whether an incoming message from `partner` is already read on another device of ours.
    func covers(_ partner: String, _ message: ReadSync.Boundary) -> Bool {
        lock.withLock { load().covers(partner: partner, message: message.core) }
    }

    /// A marker from another device: the core applies it when it is from our own account and later.
    func apply(_ partner: String, marker: ReadSync.Boundary, fromOwnAccount: Bool, ownAccount: String) -> ReadSync.Outcome {
        ReadSync.Outcome(changing {
            $0.applyMarker(partner: partner, marker: marker.core, fromOwnAccount: fromOwnAccount, ownAccount: ownAccount)
        })
    }

    /// Read here: the boundary moves and the marker waits to go out. True when it moved.
    func noteRead(_ partner: String, _ boundary: ReadSync.Boundary) -> Bool {
        changing { $0.noteRead(partner: partner, boundary: boundary.core) }
    }

    /// What is to be sent now; pending is emptied.
    func takePending() -> [String: ReadSync.Boundary] {
        let taken = changing { $0.takePending() }
        return Dictionary(uniqueKeysWithValues: taken.map { ($0.partner, ReadSync.Boundary($0.boundary)) })
    }

    /// A send that failed: back into pending, unless reading moved further meanwhile.
    func returnPending(_ unsent: [String: ReadSync.Boundary]) {
        changing { $0.returnPending(unsent: unsent.map { PartnerBoundary(partner: $0.key, boundary: $0.value.core) }) }
    }

    var hasPending: Bool { lock.withLock { load().hasPending() } }

    /// Change the state and keep it.
    private func changing<T>(_ body: (ReadMarkerState) -> T) -> T {
        lock.withLock {
            let state = load()
            let result = body(state)
            if let bytes = try? state.toBytes() { try? store().put(Self.key, bytes) }
            return result
        }
    }

    /// Call under `lock`.
    private func load() -> ReadMarkerState {
        if let held { return held }
        let state: ReadMarkerState
        if let kept = try? store().get(Self.key) {
            state = ReadMarkerState.fromBytes(kept: kept)
        } else {
            state = ReadMarkerState()
            // JSON by rule 6's exception — an earlier build's format, read once.
            if let v1 = try? store().get(Self.legacyKey),
               let boundaries = try? JSONDecoder().decode([String: ReadSync.Boundary].self, from: v1) {
                for (partner, boundary) in boundaries {
                    _ = state.advance(partner: partner, to: boundary.core)
                }
                if let bytes = try? state.toBytes() { try? store().put(Self.key, bytes) }
            }
            try? store().remove(Self.legacyKey)
        }
        held = state
        return state
    }
}

// MARK: - Outbox

/// Boundaries moved by reading on this device, waiting to go to our other devices. Not on every
/// read: at most every `interval` plus up to `jitter`, and at once when the app leaves the screen,
/// so the relay sees one own-device envelope now and then rather than one per opened chat. What is
/// waiting is kept with the boundaries (the core's state), so a restart before the send keeps it.
@MainActor
final class ReadSyncOutbox {

    static let shared = ReadSyncOutbox(observesLeaving: true)

    static let interval: TimeInterval = 120
    static let jitter: TimeInterval = 60

    private var flushTask: Task<Void, Never>?

    init(observesLeaving: Bool = false) {
        guard observesLeaving else { return }
        // Leaving the screen sends what is pending at once: the next chance may be hours away.
        // On resigning active, not on entering the background: by then the transport cancels its
        // requests, and on 2026-10-15 the phone's first markers were cancelled exactly so.
        // Coming back sends whatever an earlier try could not.
        #if canImport(UIKit)
        let leaving = UIApplication.willResignActiveNotification
        let returning = UIApplication.didBecomeActiveNotification
        #elseif canImport(AppKit)
        let leaving = NSApplication.didResignActiveNotification
        let returning = NSApplication.didBecomeActiveNotification
        #endif
        NotificationCenter.default.addObserver(forName: leaving, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ReadSyncOutbox.shared.flushOnLeaving() }
        }
        NotificationCenter.default.addObserver(forName: returning, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard ReadSyncOutbox.shared.hasPending else { return }
                Task { await ReadSyncOutbox.shared.flush() }
            }
        }
    }

    private func flushOnLeaving() {
        guard hasPending else { return }
        #if canImport(UIKit)
        // A few seconds is all the send needs; the task only keeps the app awake for them.
        let task = UIApplication.shared.beginBackgroundTask(expirationHandler: nil)
        Task {
            await flush()
            UIApplication.shared.endBackgroundTask(task)
        }
        #else
        Task { await flush() }
        #endif
    }
    /// Replaced in tests; sends the encoded markers to our other devices. True when nothing is
    /// owed any more; false keeps them for another try.
    var send: (Data) async -> Bool = { payload in
        guard let userId = await AuthSessionManager.shared.currentUserId,
              let deviceId = await AuthSessionManager.shared.currentDeviceId, !deviceId.isEmpty else { return false }
        return await MultiDeviceSendCoordinator.shared.sendReadMarkers(
            payload, senderUserId: userId, senderDeviceId: deviceId
        )
    }

    /// Where this device's own reading is held too: an older copy arriving later is read already.
    var boundaries: ReadBoundaries = .shared

    /// The person has read the chat with `partner` up to `boundary` on this device.
    func noteRead(partner: String, boundary: ReadSync.Boundary) {
        guard boundaries.noteRead(partner, boundary) else { return }
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        let delay = Self.interval + Double.random(in: 0...Self.jitter)
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    /// The chat's newest incoming message is the boundary: what was on screen has been read.
    func noteRead(chatId: String) {
        guard let chat = try? LocalRepositories.chats.chat(chatId),
              let window = try? LocalRepositories.messages.messages(inChat: chatId, before: nil, limit: 50),
              let newest = window.last(where: { !$0.isSentByMe }) else { return }
        noteRead(partner: chat.peerId, boundary: ReadSync.Boundary(of: newest))
    }

    func flush() async {
        flushTask?.cancel()
        flushTask = nil
        let sending = boundaries.takePending()
        guard !sending.isEmpty else { return }
        guard let payload = ReadSync.encode(sending), await send(payload) else {
            // Back into pending, unless reading has moved a boundary further meanwhile.
            boundaries.returnPending(sending)
            scheduleFlush()
            return
        }
    }

    var hasPending: Bool { boundaries.hasPending }
}
