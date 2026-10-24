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
    }

    enum Outcome: Equatable { case apply, ignore, drop }

    // MARK: - The rule, pure (construct-protos conformance/knst_read_markers.json)

    /// Strictly after, on (sent_at_ms, message_id), the id compared as bytes.
    static func isLater(_ a: Boundary, than b: Boundary) -> Bool {
        if a.sentAtMs != b.sentAtMs { return a.sentAtMs > b.sentAtMs }
        return b.messageId.utf8.lexicographicallyPrecedes(a.messageId.utf8)
    }

    /// An incoming message is read when it is at or before the boundary.
    static func covers(_ boundary: Boundary, _ message: Boundary) -> Bool {
        !isLater(message, than: boundary)
    }

    /// What a received marker does. One not from our own account is dropped, whatever it says.
    static func outcome(of marker: Boundary, held: Boundary?, fromOwnAccount: Bool) -> Outcome {
        guard fromOwnAccount else { return .drop }
        guard let held else { return .apply }
        return isLater(marker, than: held) ? .apply : .ignore
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

    /// How many of the chat's unread messages a boundary leaves unread. Reads the newest messages
    /// only: the unread ones are the newest `unread` incoming messages of the chat.
    static func unreadLeft(
        inChat chatId: String, unread: Int, boundary: Boundary, messages: any MessageStore
    ) -> Int {
        guard unread > 0 else { return 0 }
        // Outgoing messages sit between the incoming ones; a margin keeps them from crowding the
        // window out.
        let window = (try? messages.messages(inChat: chatId, before: nil, limit: unread * 2 + 50)) ?? []
        let incoming = window.filter { !$0.isSentByMe }.suffix(unread)
        return min(unread, incoming.filter { !covers(boundary, Boundary(of: $0)) }.count)
    }
}

// MARK: - Boundaries held

/// The read boundary per partner (`ServerUserId`, lowercased) this device holds — moved by reading
/// here and by markers from our other devices. Read from the receive path on any thread.
final class ReadBoundaries: @unchecked Sendable {

    static let shared = ReadBoundaries()

    /// Through `LocalRepositories.keyValue`, so it goes with the account's store.
    static let key = "construct.readBoundaries.v1"

    private let lock = NSLock()
    private var held: [String: ReadSync.Boundary]?

    init() {
        NotificationCenter.default.addObserver(forName: .localStoreReplaced, object: nil, queue: nil) { [weak self] _ in
            self?.lock.withLock { self?.held = nil }
        }
    }

    func boundary(for partner: String) -> ReadSync.Boundary? {
        lock.withLock { load()[partner.lowercased()] }
    }

    /// Moves the boundary if `boundary` is later; true when it moved.
    @discardableResult
    func advance(_ partner: String, to boundary: ReadSync.Boundary) -> Bool {
        lock.withLock {
            var all = load()
            let key = partner.lowercased()
            if let current = all[key], !ReadSync.isLater(boundary, than: current) { return false }
            all[key] = boundary
            held = all
            if let data = try? JSONEncoder().encode(all) {
                try? LocalRepositories.keyValue.put(Self.key, data)
            }
            return true
        }
    }

    /// Whether an incoming message from `partner` is already read on another device of ours.
    func covers(_ partner: String, _ message: ReadSync.Boundary) -> Bool {
        guard let boundary = boundary(for: partner) else { return false }
        return ReadSync.covers(boundary, message)
    }

    /// Call under `lock`.
    private func load() -> [String: ReadSync.Boundary] {
        if let held { return held }
        let loaded = (try? LocalRepositories.keyValue.get(Self.key))
            .flatMap { try? JSONDecoder().decode([String: ReadSync.Boundary].self, from: $0) } ?? [:]
        held = loaded
        return loaded
    }
}

// MARK: - Outbox

/// Boundaries moved by reading on this device, waiting to go to our other devices. Not on every
/// read: at most every `interval` plus up to `jitter`, and at once when the app leaves the screen,
/// so the relay sees one own-device envelope now and then rather than one per opened chat.
@MainActor
final class ReadSyncOutbox {

    static let shared = ReadSyncOutbox(observesLeaving: true)

    static let interval: TimeInterval = 120
    static let jitter: TimeInterval = 60

    private var pending: [String: ReadSync.Boundary] = [:]
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
        guard boundaries.advance(partner, to: boundary) else { return }
        pending[partner.lowercased()] = boundary
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
        guard !pending.isEmpty, let payload = ReadSync.encode(pending) else { return }
        let sending = pending
        pending = [:]
        guard await send(payload) else {
            // Back into the outbox, unless reading has moved a boundary further meanwhile.
            for (partner, boundary) in sending {
                if let newer = pending[partner], ReadSync.isLater(newer, than: boundary) { continue }
                pending[partner] = boundary
            }
            scheduleFlush()
            return
        }
    }

    var hasPending: Bool { !pending.isEmpty }
}
