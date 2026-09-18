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
//  - CTCallRecord.peerName, endedAt, directionRaw
//  - On-disk media ≥ 512 MiB (counted, not a failed snapshot)
//

import CoreData
import Foundation
import Security

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

    static func make(userId: String, sourceDeviceId: String) -> HistorySnapshotIdentity {
        var snapshotId = Data(count: 16)
        snapshotId.withUnsafeMutableBytes { ptr in
            _ = SecRandomCopyBytes(kSecRandomDefault, 16, ptr.baseAddress!)
        }
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

    func encodeTranscript(context: NSManagedObjectContext) -> AsyncThrowingStream<HistoryRecord, Error> {
        stream(phase: 1, context: context)
    }

    func encodeMedia(context: NSManagedObjectContext) -> AsyncThrowingStream<HistoryRecord, Error> {
        stream(phase: 2, context: context)
    }

    /// Phase 3: transcript then media, one End. File / CTHF caller.
    func encodeAll(context: NSManagedObjectContext) -> AsyncThrowingStream<HistoryRecord, Error> {
        stream(phase: 3, context: context)
    }

    // MARK: - Stream

    private func stream(
        phase: UInt32,
        context: NSManagedObjectContext
    ) -> AsyncThrowingStream<HistoryRecord, Error> {
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
        yield: (HistoryRecord) -> Void
    ) throws {
        guard let userRaw = HistoryAccountID.raw(identity.userId) else {
            throw HistorySnapshotError.malformed
        }

        let lifted = try liftMessages(context: context)
        let mediaPlan = mediaPlan(from: lifted)

        if phase == 1 || phase == 3 {
            let contacts = try fetchContacts(context: context)
            let chats = try fetchChats(context: context)
            let hints = try fetchHints(context: context)
            let calls = try fetchCalls(context: context)
            let emittedIds = Set(lifted.map(\.id))
            let reactions = try fetchReactions(context: context)
                .filter { emittedIds.contains($0.targetMessageId.lowercased()) }

            yield(.manifest(makeManifest(
                phase: phase,
                userRaw: userRaw,
                contacts: contacts.count,
                chats: chats.count,
                messages: lifted.count,
                reactions: reactions.count,
                media: phase == 3 ? mediaPlan : []
            )))
            for contact in contacts { yield(.contact(encodeContact(contact))) }
            for chat in chats { yield(.chat(encodeChat(chat))) }
            for hint in hints { yield(.peerDevice(encodeHint(hint))) }
            for call in calls { yield(.call(encodeCall(call))) }
            for message in lifted { yield(.message(message)) }
            for reaction in reactions { yield(.reaction(encodeReaction(reaction))) }
        }

        if phase == 2 {
            yield(.manifest(makeManifest(
                phase: 2,
                userRaw: userRaw,
                contacts: 0, chats: 0, messages: 0, reactions: 0,
                media: mediaPlan
            )))
        }

        if phase == 2 || phase == 3 {
            for planned in mediaPlan {
                if let blob = loadBlob(planned) {
                    yield(.mediaBlob(blob))
                }
            }
        }

        yield(.end)
    }

    // MARK: - Message lift

    private func liftMessages(context: NSManagedObjectContext) throws -> [Construct_Client_History_V1_HistoryMessage] {
        var out: [Construct_Client_History_V1_HistoryMessage] = []
        let req = Message.fetchRequest()
        req.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
        req.fetchBatchSize = Self.fetchBatchSize
        let rows = try context.fetch(req)
        for row in rows {
            if let wire = lift(row) { out.append(wire) }
        }
        return out
    }

    private func lift(_ message: Message) -> Construct_Client_History_V1_HistoryMessage? {
        if message.contentType.isEphemeral {
            counters.messageControlSkipped += 1
            return nil
        }
        let plaintext = MessageDisplayCache.shared.payloadData(for: message)
        if plaintext.isEmpty {
            counters.messageUndecryptable += 1
            return nil
        }
        if SessionControlCodec.decode(plaintext) != nil {
            counters.messageControlSkipped += 1
            return nil
        }
        let stored = LocalMessagePayload.decode(plaintext)
        if MessageContentType.isControlPayload(stored.displayString) {
            counters.messageControlSkipped += 1
            return nil
        }
        guard let body = HistoryBodyCodec.lift(stored: stored) else {
            counters.messageLegacyUnconvertible += 1
            return nil
        }
        var wire = Construct_Client_History_V1_HistoryMessage()
        wire.id = HistorySnapshotDisposition.lowercaseMessageId(message.id)
        if let from = HistoryAccountID.raw(message.fromUserId) { wire.fromUserID = from }
        if let to = HistoryAccountID.raw(message.toUserId) { wire.toUserID = to }
        wire.timestampUnixMs = Int64((message.timestamp.timeIntervalSince1970 * 1000).rounded())
        wire.isSentByMe = message.isSentByMe
        wire.body = body
        if let reply = message.replyToMessageId, !reply.isEmpty {
            wire.replyToMessageID = HistorySnapshotDisposition.lowercaseMessageId(reply)
        }
        if let replyContent = message.replyToContent, !replyContent.isEmpty {
            wire.replyToContent = replyContent
        }
        wire.isEdited = message.isEdited
        if let edited = message.editedAt {
            wire.editedAtUnixMs = Int64((edited.timeIntervalSince1970 * 1000).rounded())
        }
        if let transcript = message.transcriptText, !transcript.isEmpty {
            wire.transcriptText = transcript
        }
        if let lang = message.transcriptLanguage, !lang.isEmpty {
            wire.transcriptLanguage = lang
        }
        if let generated = message.transcriptGeneratedAt {
            wire.transcriptGeneratedAtUnix = Int64(generated.timeIntervalSince1970.rounded())
        }
        wire.suiteID = UInt32(message.suiteId)
        return wire
    }

    // MARK: - Media

    private struct PlannedBlob {
        let id: String
        let mime: String
        let size: UInt64
    }

    private func mediaPlan(
        from messages: [Construct_Client_History_V1_HistoryMessage]
    ) -> [PlannedBlob] {
        var refs: [String: String] = [:]
        for message in messages {
            guard let body = message.body else { continue }
            for ref in HistoryAccountID.mediaRefs(in: body) {
                if refs[ref.id] == nil { refs[ref.id] = ref.mime }
            }
        }
        var planned: [PlannedBlob] = []
        for (id, mime) in refs {
            guard let size = MediaManager.onDiskFileSize(mediaId: id) else { continue }
            if size >= HistorySnapshotCodec.maxRecordBytes {
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

    private func loadBlob(_ planned: PlannedBlob) -> Construct_Client_History_V1_HistoryMediaBlob? {
        guard let data = MediaManager.loadOnDisk(mediaId: planned.id) else { return nil }
        var blob = Construct_Client_History_V1_HistoryMediaBlob()
        blob.mediaID = planned.id
        blob.mimeType = planned.mime
        blob.blob = data
        return blob
    }

    // MARK: - Fetches

    private func fetchContacts(context: NSManagedObjectContext) throws -> [User] {
        let req = User.fetchRequest()
        req.predicate = NSPredicate(format: "id != %@", identity.userId)
        req.sortDescriptors = [NSSortDescriptor(key: "id", ascending: true)]
        return try context.fetch(req)
    }

    private func fetchChats(context: NSManagedObjectContext) throws -> [Chat] {
        let req = Chat.fetchRequest()
        req.sortDescriptors = [NSSortDescriptor(key: "id", ascending: true)]
        return try context.fetch(req)
    }

    private func fetchHints(context: NSManagedObjectContext) throws -> [PeerDevice] {
        let req = PeerDevice.fetchRequest()
        req.sortDescriptors = [NSSortDescriptor(key: "firstSeenAt", ascending: true)]
        return try context.fetch(req)
    }

    private func fetchCalls(context: NSManagedObjectContext) throws -> [CTCallRecord] {
        let req = CTCallRecord.fetchRequest()
        req.sortDescriptors = [NSSortDescriptor(key: "startedAt", ascending: true)]
        return try context.fetch(req)
    }

    private func fetchReactions(context: NSManagedObjectContext) throws -> [Reaction] {
        let req = Reaction.fetchRequest()
        req.sortDescriptors = [NSSortDescriptor(key: "timestampMs", ascending: true)]
        return try context.fetch(req)
    }

    // MARK: - Encode rows

    private func encodeContact(_ user: User) -> Construct_Client_History_V1_HistoryContact {
        var c = Construct_Client_History_V1_HistoryContact()
        if let raw = HistoryAccountID.raw(user.id) { c.userID = raw }
        c.username = user.username
        c.displayName = user.displayName
        c.localAlias = user.localAlias ?? ""
        c.avatar = user.avatarData ?? Data()
        c.isContact = user.isContact
        c.isBlocked = user.isBlocked
        c.amISharingWith = user.amISharingWith
        c.isSharingWithMe = user.isSharingWithMe
        if let added = user.addedAt {
            c.addedAtUnix = Int64(added.timeIntervalSince1970.rounded())
        }
        if let shared = user.sharedWithMeAt {
            c.sharedWithMeAtUnix = Int64(shared.timeIntervalSince1970.rounded())
        }
        return c
    }

    private func encodeChat(_ chat: Chat) -> Construct_Client_History_V1_HistoryChat {
        var c = Construct_Client_History_V1_HistoryChat()
        if let peer = chat.otherUser?.id, let raw = HistoryAccountID.raw(peer) {
            c.otherUserID = raw
        }
        c.isPinned = chat.isPinned
        c.isMuted = chat.isMuted
        return c
    }

    private func encodeHint(_ device: PeerDevice) -> Construct_Client_History_V1_HistoryPeerDevice {
        var h = Construct_Client_History_V1_HistoryPeerDevice()
        if let raw = HistoryAccountID.raw(device.accountId) { h.accountID = raw }
        h.deviceID = device.deviceId.lowercased()
        h.identityKey = device.identityKey
        h.firstSeenAtUnix = Int64(device.firstSeenAt.timeIntervalSince1970.rounded())
        return h
    }

    private func encodeCall(_ call: CTCallRecord) -> Construct_Client_History_V1_HistoryCall {
        var c = Construct_Client_History_V1_HistoryCall()
        c.id = call.id
        if let raw = HistoryAccountID.raw(call.peerUserId) { c.peerUserID = raw }
        c.isOutgoing = call.direction == .outgoing
        c.status = UInt32(UInt16(bitPattern: call.statusRaw))
        if let started = call.startedAt {
            c.startedAtUnix = Int64(started.timeIntervalSince1970.rounded())
        }
        c.durationSeconds = Int64(call.durationSeconds)
        return c
    }

    private func encodeReaction(_ reaction: Reaction) -> Construct_Client_History_V1_HistoryReaction {
        var r = Construct_Client_History_V1_HistoryReaction()
        r.targetMessageID = HistorySnapshotDisposition.lowercaseMessageId(reaction.targetMessageId)
        if let raw = HistoryAccountID.raw(reaction.reactorUserId) { r.reactorUserID = raw }
        r.emoji = reaction.emoji
        r.timestampMs = reaction.timestampMs
        return r
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
