//
//  HistorySnapshotImporter.swift
//  Construct Messenger
//
//  Additive Core Data projection of a CTH1 stream. Never replaces store
//  files, never writes the stream cursor, never imports a ratchet.
//

import CoreData
import Foundation

enum HistorySkipReason: Equatable {
    case bodyUnknown
    case hintDroppedBadId
    case mediaAlreadyPresent
    case reactionTargetMissing
}

enum HistoryApplyResult: Equatable {
    case applied
    case conflictKeepExisting
    case skipped(HistorySkipReason)
    case ignored
}

struct HistoryImportSummary: Equatable {
    var applied: Int = 0
    var conflictKeepExisting: Int = 0
    var skipped: [HistorySkipReason: Int] = [:]

    mutating func add(_ result: HistoryApplyResult) {
        switch result {
        case .applied: applied += 1
        case .conflictKeepExisting: conflictKeepExisting += 1
        case .skipped(let reason): skipped[reason, default: 0] += 1
        case .ignored: break
        }
    }
}

struct HistorySnapshotImporter {
    static let saveBatchSize = 200

    /// Apply one already-decoded record. Does not save. Caller owns the queue.
    @discardableResult
    func apply(
        _ record: HistoryRecord,
        expectedUserId: String,
        in context: NSManagedObjectContext
    ) throws -> HistoryApplyResult {
        switch record {
        case .manifest(let manifest):
            guard let expectedRaw = HistoryAccountID.raw(expectedUserId) else {
                throw HistorySnapshotError.malformed
            }
            switch HistorySnapshotDisposition.accept(manifest: manifest, expectedUserId: expectedRaw) {
            case .failure(let err):
                throw err
            case .success:
                return .ignored
            }
        case .contact(let contact):
            return try applyContact(contact, in: context)
        case .chat(let chat):
            return try applyChat(chat, in: context)
        case .message(let message):
            return try applyMessage(message, expectedUserId: expectedUserId, in: context)
        case .reaction(let reaction):
            return try applyReaction(reaction, in: context)
        case .peerDevice(let hint):
            return try applyPeerHint(hint, in: context)
        case .call(let call):
            return try applyCall(call, in: context)
        case .mediaBlob(let blob):
            return applyMedia(blob)
        case .skipped(let type, _):
            if type == HistoryRecordType.message {
                return .skipped(.bodyUnknown)
            }
            return .ignored
        case .end:
            return .ignored
        }
    }

    /// Apply a whole decoded stream. One save per `saveBatchSize` records.
    func importRecords(
        _ records: [HistoryRecord],
        expectedUserId: String,
        in context: NSManagedObjectContext
    ) throws -> HistoryImportSummary {
        var batch = makeBatch(expectedUserId: expectedUserId, in: context)
        for record in records {
            try batch.apply(record)
        }
        return try batch.finish()
    }

    /// The same work as `importRecords`, fed one record at a time.
    ///
    /// A caller reading a `.cthf` off disk never has the whole array: it decodes a 64 KiB chunk,
    /// gets whatever records that chunk completed, and moves on. Batching lives here rather than at
    /// the call site so both entry points save on the same boundary.
    func makeBatch(
        expectedUserId: String,
        in context: NSManagedObjectContext
    ) -> Batch {
        Batch(importer: self, expectedUserId: expectedUserId, context: context)
    }

    /// One save per `HistorySnapshotImporter.saveBatchSize` applied records, plus a final save.
    /// Not reusable after `finish()`.
    struct Batch {
        private let importer: HistorySnapshotImporter
        private let expectedUserId: String
        private let context: NSManagedObjectContext
        private var summary = HistoryImportSummary()
        private var sinceSave = 0

        init(
            importer: HistorySnapshotImporter,
            expectedUserId: String,
            context: NSManagedObjectContext
        ) {
            self.importer = importer
            self.expectedUserId = expectedUserId
            self.context = context
        }

        mutating func apply(_ record: HistoryRecord) throws {
            let result = try importer.apply(record, expectedUserId: expectedUserId, in: context)
            summary.add(result)
            sinceSave += 1
            if sinceSave >= HistorySnapshotImporter.saveBatchSize {
                try context.saveOrThrow(category: "HistorySync")
                sinceSave = 0
            }
        }

        mutating func finish() throws -> HistoryImportSummary {
            if sinceSave > 0 {
                try context.saveOrThrow(category: "HistorySync")
                sinceSave = 0
            }
            return summary
        }
    }

    // MARK: - Contact

    private func applyContact(
        _ contact: Construct_Client_History_V1_HistoryContact,
        in context: NSManagedObjectContext
    ) throws -> HistoryApplyResult {
        guard let id = HistoryAccountID.dashed(contact.userID) else {
            throw HistorySnapshotError.malformed
        }
        let user: User
        if let existing = try fetchUser(id: id, in: context) {
            user = existing
        } else {
            user = User(context: context)
            user.id = id
            user.username = ""
            user.displayName = ""
            user.isSharingWithMe = false
            user.isBlocked = false
            user.amISharingWith = false
            user.isContact = false
        }

        if user.username.isEmpty, !contact.username.isEmpty {
            user.username = contact.username
        }
        if isBlankDisplayName(user.displayName, userId: id), !contact.displayName.isEmpty {
            user.displayName = contact.displayName
        }
        if (user.localAlias ?? "").isEmpty, !contact.localAlias.isEmpty {
            user.localAlias = contact.localAlias
        }
        if (user.avatarData == nil || user.avatarData?.isEmpty == true), !contact.avatar.isEmpty {
            user.avatarData = contact.avatar
        }

        user.isContact = HistorySnapshotDisposition.contactShareFlag(
            snapshot: contact.isContact, alreadyTrueOnReceiver: user.isContact
        )
        user.amISharingWith = HistorySnapshotDisposition.contactShareFlag(
            snapshot: contact.amISharingWith, alreadyTrueOnReceiver: user.amISharingWith
        )
        user.isSharingWithMe = HistorySnapshotDisposition.contactShareFlag(
            snapshot: contact.isSharingWithMe, alreadyTrueOnReceiver: user.isSharingWithMe
        )
        // Block is a local decision: only false→true, never unblock.
        if contact.isBlocked { user.isBlocked = true }

        if user.addedAt == nil {
            if contact.addedAtUnix > 0 {
                user.addedAt = Date(timeIntervalSince1970: TimeInterval(contact.addedAtUnix))
            } else {
                user.addedAt = Date()
            }
        }
        if user.sharedWithMeAt == nil, contact.sharedWithMeAtUnix > 0 {
            user.sharedWithMeAt = Date(timeIntervalSince1970: TimeInterval(contact.sharedWithMeAtUnix))
        }
        // Deliberately not copied: knownIdentityKey, ktStatus, hybridCapable, publicKey.
        return .applied
    }

    // MARK: - Chat

    private func applyChat(
        _ chat: Construct_Client_History_V1_HistoryChat,
        in context: NSManagedObjectContext
    ) throws -> HistoryApplyResult {
        let key = HistorySnapshotDisposition.chatUpsertKey(otherUserId: chat.otherUserID)
        guard let peerId = HistoryAccountID.dashed(key) else {
            throw HistorySnapshotError.malformed
        }
        guard let result = try Chat.findOrCreate(forUserId: peerId, in: context) else {
            throw HistorySnapshotError.malformed
        }
        let row = result.chat
        // Additive: do not unpin / unmute something this device already set.
        if chat.isPinned { row.isPinned = true }
        if chat.isMuted { row.isMuted = true }
        row.unreadCount = 0
        // Chat.sessionId left nil — a ratchet on the offering device is not this device's.
        return .applied
    }

    // MARK: - Message

    private func applyMessage(
        _ message: Construct_Client_History_V1_HistoryMessage,
        expectedUserId: String,
        in context: NSManagedObjectContext
    ) throws -> HistoryApplyResult {
        let id = HistorySnapshotDisposition.lowercaseMessageId(message.id)
        guard !id.isEmpty else { throw HistorySnapshotError.malformed }
        if try fetchMessage(id: id, in: context) != nil {
            return .conflictKeepExisting
        }
        guard let body = message.body else {
            throw HistorySnapshotError.unsetBody
        }
        let stored = try HistoryBodyCodec.store(body)
        guard let from = HistoryAccountID.dashed(message.fromUserID),
              let to = HistoryAccountID.dashed(message.toUserID) else {
            throw HistorySnapshotError.malformed
        }
        let expected = expectedUserId.lowercased()
        let peer: String
        if from == expected { peer = to }
        else if to == expected { peer = from }
        else { peer = message.isSentByMe ? to : from }
        guard !peer.isEmpty else { throw HistorySnapshotError.malformed }

        guard let chatResult = try Chat.findOrCreate(forUserId: peer, in: context) else {
            throw HistorySnapshotError.malformed
        }
        let row = Message(context: context)
        row.id = id
        row.fromUserId = from
        row.toUserId = to
        row.timestamp = Date(timeIntervalSince1970: TimeInterval(message.timestampUnixMs) / 1000)
        // CTH1 v1 carries no server-order field, so an imported row has no server position and
        // takes a local key at its display timestamp. Written here rather than left to the
        // launch-time backfill: between the import and the next launch the column would be nil,
        // and every transcript fetch in that window orders these rows at random.
        row.serverOrderKey = ServerMessageOrder.local(timestamp: row.timestamp, messageId: id)
        row.isSentByMe = message.isSentByMe
        row.retryCount = 0
        row.chat = chatResult.chat
        row.suiteId = UInt16(truncatingIfNeeded: message.suiteID)
        if !message.replyToMessageID.isEmpty {
            row.replyToMessageId = HistorySnapshotDisposition.lowercaseMessageId(message.replyToMessageID)
        }
        if !message.replyToContent.isEmpty {
            row.replyToContent = message.replyToContent
        }
        row.isEdited = message.isEdited
        if message.editedAtUnixMs > 0 {
            row.editedAt = Date(timeIntervalSince1970: TimeInterval(message.editedAtUnixMs) / 1000)
        }
        if !message.transcriptText.isEmpty {
            row.transcriptText = message.transcriptText
        }
        if !message.transcriptLanguage.isEmpty {
            row.transcriptLanguage = message.transcriptLanguage
        }
        if message.transcriptGeneratedAtUnix > 0 {
            row.transcriptGeneratedAt = Date(timeIntervalSince1970: TimeInterval(message.transcriptGeneratedAtUnix))
        }
        row.applyStoredEncryption(plaintextData: stored, contactId: peer)
        // Own → .sent (never .delivered: this device did not see that receipt).
        // Incoming is not .sending — the bubble already exists.
        // Raw write: the guarded setter is for live writers racing receipts.
        row.deliveryStatusRaw = (message.isSentByMe ? DeliveryStatus.sent : DeliveryStatus.delivered).rawValue
        chatResult.chat.unreadCount = 0
        chatResult.chat.applyPreview(text: row.previewText, timestamp: row.timestamp)
        return .applied
    }

    // MARK: - Reaction

    private func applyReaction(
        _ reaction: Construct_Client_History_V1_HistoryReaction,
        in context: NSManagedObjectContext
    ) throws -> HistoryApplyResult {
        let target = HistorySnapshotDisposition.lowercaseMessageId(reaction.targetMessageID)
        guard !target.isEmpty else { throw HistorySnapshotError.malformed }
        guard try fetchMessage(id: target, in: context) != nil else {
            return .skipped(.reactionTargetMissing)
        }
        guard let reactor = HistoryAccountID.dashed(reaction.reactorUserID) else {
            throw HistorySnapshotError.malformed
        }
        if ReactionStore.row(targetMessageId: target, reactorUserId: reactor, in: context) != nil {
            return .conflictKeepExisting
        }
        let row = Reaction(context: context)
        row.targetMessageId = target
        row.reactorUserId = reactor.lowercased()
        row.emoji = reaction.emoji
        row.timestampMs = reaction.timestampMs
        row.receivedAt = Date()
        return .applied
    }

    // MARK: - Peer hint

    private func applyPeerHint(
        _ hint: Construct_Client_History_V1_HistoryPeerDevice,
        in context: NSManagedObjectContext
    ) throws -> HistoryApplyResult {
        guard HistorySnapshotDisposition.peerDeviceHintAcceptable(
            deviceId: hint.deviceID, identityKey: hint.identityKey
        ) else {
            return .skipped(.hintDroppedBadId)
        }
        guard let accountId = HistoryAccountID.dashed(hint.accountID) else {
            throw HistorySnapshotError.malformed
        }
        let deviceId = hint.deviceID.lowercased()
        if try fetchPeerDevice(deviceId: deviceId, in: context) != nil {
            return .conflictKeepExisting
        }
        let row = PeerDevice(context: context)
        row.deviceId = deviceId
        row.accountId = accountId
        row.identityKey = hint.identityKey
        row.firstSeenAt = hint.firstSeenAtUnix > 0
            ? Date(timeIntervalSince1970: TimeInterval(hint.firstSeenAtUnix))
            : Date()
        return .applied
    }

    // MARK: - Call

    private func applyCall(
        _ call: Construct_Client_History_V1_HistoryCall,
        in context: NSManagedObjectContext
    ) throws -> HistoryApplyResult {
        guard !call.id.isEmpty else { throw HistorySnapshotError.malformed }
        if try fetchCall(id: call.id, in: context) != nil {
            return .conflictKeepExisting
        }
        guard let peerId = HistoryAccountID.dashed(call.peerUserID) else {
            throw HistorySnapshotError.malformed
        }
        let status = CTCallRecord.Status(rawValue: Int16(truncatingIfNeeded: call.status)) ?? .completed
        let started = call.startedAtUnix > 0
            ? Date(timeIntervalSince1970: TimeInterval(call.startedAtUnix))
            : Date()
        let ended: Date?
        if status == .completed, call.durationSeconds > 0 {
            ended = started.addingTimeInterval(TimeInterval(call.durationSeconds))
        } else {
            ended = nil
        }
        let peerName = try fetchUser(id: peerId, in: context)?.displayName ?? ""
        _ = CTCallRecord.create(
            id: call.id,
            peerUserId: peerId,
            peerName: peerName,
            direction: call.isOutgoing ? .outgoing : .incoming,
            status: status,
            startedAt: started,
            endedAt: ended,
            durationSeconds: Int32(clamping: call.durationSeconds),
            in: context
        )
        return .applied
    }

    // MARK: - Media

    private func applyMedia(_ blob: Construct_Client_History_V1_HistoryMediaBlob) -> HistoryApplyResult {
        guard !blob.mediaID.isEmpty else { return .ignored }
        if MediaManager.hasOnDiskFile(mediaId: blob.mediaID) {
            return .skipped(.mediaAlreadyPresent)
        }
        _ = MediaManager.importHistoryBlob(blob.blob, mediaId: blob.mediaID)
        return .applied
    }

    // MARK: - Fetch

    private func fetchUser(id: String, in context: NSManagedObjectContext) throws -> User? {
        let req = User.fetchRequest()
        req.fetchLimit = 1
        req.predicate = NSPredicate(format: "id == %@", id)
        return try context.fetch(req).first
    }

    private func fetchMessage(id: String, in context: NSManagedObjectContext) throws -> Message? {
        let req = Message.fetchRequest()
        req.fetchLimit = 1
        req.predicate = NSPredicate(format: "id ==[c] %@", id)
        return try context.fetch(req).first
    }

    private func fetchPeerDevice(deviceId: String, in context: NSManagedObjectContext) throws -> PeerDevice? {
        let req = PeerDevice.fetchRequest()
        req.fetchLimit = 1
        req.predicate = NSPredicate(format: "deviceId == %@", deviceId)
        return try context.fetch(req).first
    }

    private func fetchCall(id: String, in context: NSManagedObjectContext) throws -> CTCallRecord? {
        let req = CTCallRecord.fetchRequest()
        req.fetchLimit = 1
        req.predicate = NSPredicate(format: "id == %@", id)
        return try context.fetch(req).first
    }

    private func isBlankDisplayName(_ name: String, userId: String) -> Bool {
        name.isEmpty || name == DisplayNameGenerator.generate(from: userId)
    }
}
