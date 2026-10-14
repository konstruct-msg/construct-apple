//
//  HistorySnapshotEncoder.swift
//  Construct Messenger
//
//  Live store → CTH1 records. Decrypts on this device, lifts to wire
//  plaintext, re-encrypts nowhere. Named omissions (not forgotten fields):
//
//  - CFE session blobs / Keychain session accounts / Chat.sessionId
//  - Identity / signing / SPK / OTPK / Kyber secrets
//  - MessageKeyStore keys and contentKeyRef
//  - encryptedContent as-is
//  - CTM1 envelope and legacy UTF-8 / media JSON (lifted or counted)
//  - Group chats (reserved 0x09–0x0D; v1 never emits)
//  - Stream cursor
//  - Sealed-sender cert
//  - ProcessedMessage / HealingMessage / ACK stores
//  - User.knownIdentityKey, ktStatus, hybridCapable, User.publicKey
//  - Drafts, VEIL tickets, Privacy Pass, MediaSendCache
//  - App settings / theme / orientation / PIN-lock
//  - Recovery phrase, old-device JWTs, sticker pack blobs
//  - CallRecord.peerName, endedAt, direction
//  - On-disk media ≥ 512 MiB (counted, not a failed snapshot)
//  - Message.serverOrderKey (CTH1 v1 carries display timestamp only; the importer uses the
//    legacy fallback until the snapshot format has an explicit order field)
//

import CoreData
import Foundation
import SwiftProtobuf

struct HistoryEncodeCounters: Equatable {
    var messageUndecryptable: Int = 0
    var messageControlSkipped: Int = 0
    var messageLegacyUnconvertible: Int = 0
    var mediaTooLarge: Int = 0
}

struct HistorySnapshotIdentity {
    var userId: String
    var sourceDeviceId: String
    var snapshotId: Data
    var createdAt: Date
    var appVersion: String

    /// `snapshotId` is the one the core's sender announced (`HistorySender.snapshotId()`): the
    /// manifest must carry it, and the core refuses a stream whose manifest names another.
    /// The first four bytes of a snapshot id in hex: what a file name and every log line of one
    /// transfer carry, so the two devices' logs of it can be matched.
    static func tag(_ snapshotId: Data) -> String {
        snapshotId.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    static func make(userId: String, sourceDeviceId: String, snapshotId: Data) -> HistorySnapshotIdentity {
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
        return HistorySnapshotIdentity(
            userId: userId,
            sourceDeviceId: sourceDeviceId,
            snapshotId: snapshotId,
            createdAt: Date(),
            appVersion: version
        )
    }
}

final class HistorySnapshotEncoder {
    static let fetchBatchSize = 500

    let identity: HistorySnapshotIdentity
    private(set) var counters = HistoryEncodeCounters()

    init(identity: HistorySnapshotIdentity) {
        self.identity = identity
    }

    func encodeTranscript(context: NSManagedObjectContext) -> AsyncThrowingStream<HistoryOutbound, Error> {
        stream(phase: 1, context: context)
    }

    func encodeMedia(context: NSManagedObjectContext) -> AsyncThrowingStream<HistoryOutbound, Error> {
        stream(phase: 2, context: context)
    }

    /// Phase 3: transcript then media. File / CTHF caller.
    func encodeAll(context: NSManagedObjectContext) -> AsyncThrowingStream<HistoryOutbound, Error> {
        stream(phase: 3, context: context)
    }

    /// A phase as an array, for a caller already inside `context.perform`. Media are references:
    /// the array is the transcript plus a list of files, not their bytes.
    func collect(phase: UInt32, context: NSManagedObjectContext) throws -> [HistoryOutbound] {
        counters = HistoryEncodeCounters()
        var out: [HistoryOutbound] = []
        try emit(phase: phase, context: context, yield: { out.append($0) })
        return out
    }

    // MARK: - Stream

    private func stream(
        phase: UInt32,
        context: NSManagedObjectContext
    ) -> AsyncThrowingStream<HistoryOutbound, Error> {
        AsyncThrowingStream { continuation in
            do {
                self.counters = HistoryEncodeCounters()
                try self.emit(phase: phase, context: context, yield: { continuation.yield($0) })
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    private func emit(
        phase: UInt32,
        context: NSManagedObjectContext,
        yield: (HistoryOutbound) -> Void
    ) throws {
        guard let userRaw = HistoryAccountID.raw(identity.userId) else {
            throw HistorySnapshotError.malformed
        }

        let chats = try LocalRepositories.chats.chats().sorted { $0.id < $1.id }
        let lifted = try liftMessages(peers: Dictionary(chats.map { ($0.id, $0.peerId) }) { a, _ in a })
        let mediaPlan = mediaPlan(from: lifted.flatMap(\.media))

        if phase == 1 || phase == 3 {
            let contacts = try LocalRepositories.contacts.everyContact(except: identity.userId)
            let hints = try LocalRepositories.peerDevices.allDevices()
            let calls = try LocalRepositories.calls.calls(limit: Int(Int32.max)).reversed()
            let emittedIds = Set(lifted.map(\.id))
            let reactions = try LocalRepositories.reactions.allReactions()
                .filter { emittedIds.contains($0.targetMessageId.lowercased()) }

            yield(.record(.manifest(makeManifest(
                phase: phase,
                userRaw: userRaw,
                contacts: contacts.count,
                chats: chats.count,
                messages: lifted.count,
                reactions: reactions.count,
                media: phase == 3 ? mediaPlan : []
            ))))
            func record(_ type: UInt8, _ proto: Data) {
                yield(.record(.transcript(type: type, proto: proto)))
            }
            for contact in contacts { record(HistoryRecordType.contact, historyExportContact(contact: contact.local)) }
            for chat in chats {
                record(HistoryRecordType.chat, historyExportChat(peerId: chat.peerId, isPinned: chat.isPinned))
            }
            for hint in hints { record(HistoryRecordType.peer, historyExportPeerDevice(device: hint.local)) }
            for call in calls { record(HistoryRecordType.call, historyExportCall(call: call.local)) }
            for message in lifted { record(HistoryRecordType.message, message.proto) }
            for reaction in reactions {
                record(HistoryRecordType.reaction, historyExportReaction(reaction: reaction.local))
            }
        }

        if phase == 2 {
            yield(.record(.manifest(makeManifest(
                phase: 2,
                userRaw: userRaw,
                contacts: 0, chats: 0, messages: 0, reactions: 0,
                media: mediaPlan
            ))))
        }

        if phase == 2 || phase == 3 {
            for planned in mediaPlan {
                yield(.media(id: planned.id, mime: planned.mime))
            }
        }
    }

    // MARK: - Message lift

    private struct Lifted {
        let id: String
        let proto: Data
        let media: [(id: String, mime: String)]
    }

    /// Every message, page by page, as records; `peers` names each chat's peer.
    private func liftMessages(peers: [String: String]) throws -> [Lifted] {
        var out: [Lifted] = []
        var after: (orderKey: String, id: String)?
        while true {
            let page = try LocalRepositories.messages.allMessages(after: after, limit: Self.fetchBatchSize)
            for message in page {
                if let lifted = lift(message, chatPeer: peers[message.chatId]) { out.append(lifted) }
            }
            guard page.count == Self.fetchBatchSize, let last = page.last else { return out }
            after = (last.orderKey, last.id)
        }
    }

    private func lift(_ message: MessageRecord, chatPeer: String?) -> Lifted? {
        // iOS rows from before typed control content: a session signal or a control marker
        // stored as text. No other client wrote these.
        let stored = LocalMessagePayload.decode(message.body)
        if SessionControlCodec.decode(message.body) != nil
            || MessageContentType.isControlPayload(stored.displayString) {
            counters.messageControlSkipped += 1
            return nil
        }
        switch historyExportMessage(message: message.local, ownAccountId: identity.userId, chatPeerId: chatPeer) {
        case .record(let proto, let media):
            return Lifted(id: message.id.lowercased(), proto: proto, media: media.map { ($0.id, $0.mime) })
        case .control:
            counters.messageControlSkipped += 1
            return nil
        case .empty:
            counters.messageUndecryptable += 1
            return nil
        case .legacy:
            return liftLegacy(message, stored: stored, chatPeer: chatPeer)
        }
    }

    /// A row from before CTM1 — legacy UTF-8 or the media JSON the bubbles once read. Only this
    /// app wrote them; step 4 of the store plan converts them, and this goes with it.
    private func liftLegacy(_ message: MessageRecord, stored: LocalMessagePayload, chatPeer: String?) -> Lifted? {
        guard case .legacyUTF8(let data) = stored, let body = HistoryBodyCodec.liftLegacy(data) else {
            counters.messageLegacyUnconvertible += 1
            return nil
        }
        var wire = Construct_Client_History_V1_HistoryMessage()
        wire.id = HistorySnapshotDisposition.lowercaseMessageId(message.id)
        let who = HistorySnapshotDisposition.participants(
            storedFrom: message.fromUserId,
            storedTo: message.toUserId,
            isSentByMe: message.isSentByMe,
            ownId: identity.userId,
            chatPeerId: chatPeer
        )
        if let from = who.from.flatMap(HistoryAccountID.raw) { wire.fromUserID = from }
        if let to = who.to.flatMap(HistoryAccountID.raw) { wire.toUserID = to }
        wire.timestampUnixMs = message.timestamp.unixMs
        wire.isSentByMe = message.isSentByMe
        wire.body = body
        if let reply = message.replyToMessageId, !reply.isEmpty {
            wire.replyToMessageID = HistorySnapshotDisposition.lowercaseMessageId(reply)
        }
        if let replyContent = message.replyQuote, !replyContent.isEmpty {
            wire.replyToContent = replyContent
        }
        wire.isEdited = message.isEdited
        if let edited = message.editedAt { wire.editedAtUnixMs = edited.unixMs }
        if let transcript = message.transcript, !transcript.isEmpty { wire.transcriptText = transcript }
        if let lang = message.transcriptLanguage, !lang.isEmpty { wire.transcriptLanguage = lang }
        if let generated = message.transcriptGeneratedAt {
            wire.transcriptGeneratedAtUnix = Int64(generated.timeIntervalSince1970.rounded())
        }
        wire.suiteID = UInt32(message.suiteId)
        guard let proto = try? wire.serializedData() else {
            counters.messageLegacyUnconvertible += 1
            return nil
        }
        return Lifted(id: wire.id, proto: proto, media: HistoryAccountID.mediaRefs(in: body))
    }

    // MARK: - Media

    private struct PlannedBlob {
        let id: String
        let mime: String
        let size: UInt64
    }

    private func mediaPlan(from refs: [(id: String, mime: String)]) -> [PlannedBlob] {
        var mimes: [String: String] = [:]
        for ref in refs where mimes[ref.id] == nil { mimes[ref.id] = ref.mime }
        var planned: [PlannedBlob] = []
        for (id, mime) in mimes {
            guard let size = MediaManager.onDiskFileSize(mediaId: id) else { continue }
            if size > historyMaxBlobBytes() {
                counters.mediaTooLarge += 1
                continue
            }
            planned.append(PlannedBlob(id: id, mime: mime, size: size))
        }
        planned.sort { lhs, rhs in
            if lhs.size != rhs.size { return lhs.size < rhs.size }
            return lhs.id < rhs.id
        }
        return planned
    }

    private func makeManifest(
        phase: UInt32,
        userRaw: Data,
        contacts: Int,
        chats: Int,
        messages: Int,
        reactions: Int,
        media: [PlannedBlob]
    ) -> Construct_Client_History_V1_HistoryManifest {
        var m = Construct_Client_History_V1_HistoryManifest()
        m.formatVersion = 1
        m.snapshotID = identity.snapshotId
        m.userID = userRaw
        m.sourceDeviceID = identity.sourceDeviceId.lowercased()
        m.createdAtUnix = Int64(identity.createdAt.timeIntervalSince1970.rounded())
        m.appVersion = identity.appVersion
        m.contactCount = UInt32(contacts)
        m.chatCount = UInt32(chats)
        m.messageCount = UInt32(messages)
        m.reactionCount = UInt32(reactions)
        m.mediaBlobCount = UInt32(media.count)
        m.mediaByteCount = media.reduce(UInt64(0)) { $0 + $1.size }
        m.phase = phase
        return m
    }
}
