//
//  LocalStoreRecords.swift
//  Construct Messenger
//
//  The seam's records ↔ the core's store rows (`LocalContact`, `LocalMessage`, …): what the
//  history projection takes and returns today, and what the `LocalStore` repositories will read
//  and write (LOCAL_STORE_MIGRATION_PLAN step 3). Field for field; times cross as Unix ms, the
//  enums as their raw values, which are the crate's numbers.
//

import Foundation

extension Date {
    init(unixMs: Int64) { self.init(timeIntervalSince1970: TimeInterval(unixMs) / 1000) }
    var unixMs: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
}

extension ContactRecord {
    init(_ row: LocalContact) {
        self.init(
            id: row.id, username: row.username, displayName: row.displayName,
            localAlias: row.localAlias, avatar: row.avatar,
            knownIdentityKey: row.knownIdentityKey, accountAddress: row.accountAddress,
            isContact: row.isContact, isBlocked: row.isBlocked,
            isSharingWithMe: row.isSharingWithMe, amISharingWith: row.amISharingWith,
            sharedWithMeAt: row.sharedWithMeAt.map(Date.init(unixMs:)),
            addedAt: row.addedAt.map(Date.init(unixMs:)),
            ktStatus: KTStatus(rawValue: row.ktStatus) ?? .unverified,
            securityNotice: SecurityNotice(rawValue: row.securityNotice) ?? .none,
            profileEditedAtMs: row.profileEditedAtMs,
            pendingAvatarRef: row.pendingAvatarRef,
            pendingAvatarSince: row.pendingAvatarSince.map(Date.init(unixMs:))
        )
    }

    var local: LocalContact {
        LocalContact(
            id: id, username: username, displayName: displayName, localAlias: localAlias,
            avatar: avatar, knownIdentityKey: knownIdentityKey, accountAddress: accountAddress,
            isContact: isContact, isBlocked: isBlocked, isSharingWithMe: isSharingWithMe,
            amISharingWith: amISharingWith, sharedWithMeAt: sharedWithMeAt?.unixMs,
            addedAt: addedAt?.unixMs, ktStatus: ktStatus.rawValue,
            securityNotice: securityNotice.rawValue, profileEditedAtMs: profileEditedAtMs,
            pendingAvatarRef: pendingAvatarRef, pendingAvatarSince: pendingAvatarSince?.unixMs
        )
    }
}

extension MessageRecord {
    /// `chatId` replaces the row's: a row from the history projection comes without one.
    init(_ row: LocalMessage, chatId: String? = nil) {
        self.init(
            id: row.id, chatId: chatId ?? row.chatId, fromUserId: row.fromUserId,
            toUserId: row.toUserId, isSentByMe: row.isSentByMe,
            timestamp: Date(unixMs: row.timestamp), orderKey: row.orderKey, body: row.body,
            contentType: MessageContentType(rawValue: row.contentType) ?? .regular,
            deliveryStatus: DeliveryStatus(rawValue: row.deliveryStatus) ?? .sent,
            retryCount: row.retryCount, suiteId: UInt16(bitPattern: row.suiteId),
            isEdited: row.isEdited, editedAt: row.editedAt.map(Date.init(unixMs:)),
            replyToMessageId: row.replyToMessageId, replyQuote: row.replyToContent,
            transcript: row.transcriptText, transcriptLanguage: row.transcriptLanguage,
            transcriptGeneratedAt: row.transcriptGeneratedAt.map(Date.init(unixMs:))
        )
    }

    var local: LocalMessage {
        LocalMessage(
            id: id, chatId: chatId, fromUserId: fromUserId, toUserId: toUserId,
            isSentByMe: isSentByMe, timestamp: timestamp.unixMs, orderKey: orderKey, body: body,
            contentType: contentType.rawValue, deliveryStatus: deliveryStatus.rawValue,
            retryCount: retryCount, suiteId: Int16(bitPattern: suiteId), isEdited: isEdited,
            editedAt: editedAt?.unixMs, replyToMessageId: replyToMessageId,
            replyToContent: replyQuote, transcriptText: transcript,
            transcriptLanguage: transcriptLanguage, transcriptGeneratedAt: transcriptGeneratedAt?.unixMs
        )
    }
}

extension ReactionRecord {
    init(_ row: LocalReaction) {
        self.init(
            targetMessageId: row.targetMessageId, reactorUserId: row.reactorUserId,
            emoji: row.emoji, timestampMs: row.timestampMs,
            receivedAt: row.receivedAt.map(Date.init(unixMs:))
        )
    }

    var local: LocalReaction {
        LocalReaction(
            targetMessageId: targetMessageId, reactorUserId: reactorUserId, emoji: emoji,
            timestampMs: timestampMs, receivedAt: receivedAt?.unixMs
        )
    }
}

extension PeerDeviceRecord {
    init(_ row: LocalPeerDevice) {
        self.init(
            deviceId: row.deviceId, accountId: row.accountId, identityKey: row.identityKey,
            firstSeenAt: Date(unixMs: row.firstSeenAt)
        )
    }

    var local: LocalPeerDevice {
        LocalPeerDevice(
            deviceId: deviceId, accountId: accountId, identityKey: identityKey,
            firstSeenAt: firstSeenAt.unixMs
        )
    }
}

extension ChatRecord {
    init(_ row: LocalChat) {
        self.init(
            id: row.id, peerId: row.peerId, lastMessageText: row.lastMessageText,
            lastMessageTime: row.lastMessageTime.map(Date.init(unixMs:)), isPinned: row.isPinned,
            unreadCount: Int(row.unreadCount)
        )
    }

    var local: LocalChat {
        LocalChat(
            id: id, peerId: peerId, lastMessageText: lastMessageText,
            lastMessageTime: lastMessageTime?.unixMs, isPinned: isPinned,
            unreadCount: Int32(clamping: unreadCount)
        )
    }
}

extension CallRecord {
    init(_ row: LocalCall) {
        self.init(
            id: row.id, peerUserId: row.peerUserId, peerName: row.peerName,
            direction: Direction(rawValue: row.direction) ?? .outgoing,
            status: Status(rawValue: row.status) ?? .completed,
            startedAt: row.startedAt.map(Date.init(unixMs:)), endedAt: row.endedAt.map(Date.init(unixMs:)),
            durationSeconds: row.durationSeconds
        )
    }

    var local: LocalCall {
        LocalCall(
            id: id, peerUserId: peerUserId, peerName: peerName,
            direction: direction.rawValue, status: status.rawValue,
            startedAt: startedAt?.unixMs, endedAt: endedAt?.unixMs,
            durationSeconds: durationSeconds
        )
    }
}
