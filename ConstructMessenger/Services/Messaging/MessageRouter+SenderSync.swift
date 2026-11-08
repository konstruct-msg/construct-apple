//
//  MessageRouter+SenderSync.swift
//  Construct Messenger
//
//  MessageRouter: SENDER_SYNC handling, copies of outgoing messages from the user's other devices.
//

import Foundation
import CoreData
import SwiftProtobuf

@MainActor
extension MessageRouter {
    // MARK: - SENDER_SYNC Handling

    /// Handle an incoming SENDER_SYNC message — a copy of an outgoing message sent by
    /// the user's own other device. Decrypts using the per-device session and saves
    /// the message as an outgoing bubble in the correct conversation.
    func handleSenderSync(_ message: ChatMessage, in context: NSManagedObjectContext) {
        guard let currentUserId = AuthSessionManager.shared.currentUserId else { return }

        // A copy addressed to one of our *other* devices. The server does not route per device —
        // `messaging-service/src/core.rs` fans every envelope out to all of the recipient's
        // per-device streams — so on a three-device account each device receives the two copies
        // meant for the other two and can decrypt neither.
        //
        // The target is on the wire in the id suffix the sender writes, `-ss-<tag>`, so recognising
        // a foreign copy costs one X25519 per own device. Without it every foreign copy fails a
        // decrypt, for a message that was never ours to read.
        //
        // The tag is a MAC under a secret only the two devices share, not the device id it used to
        // be; see SenderSyncDeviceTag for what the readable form gave the relay.
        if DeviceCopyWireId.read(
            wireId: message.id,
            ourDeviceId: AuthSessionManager.shared.currentDeviceId,
            tagger: SenderSyncDeviceTag.Tagger.current,
            peerIdentityKeys: MultiDeviceSendCoordinator.shared.senderSyncPeerIdentityKeys(myUserId: currentUserId),
            // Own replicas: the cache holds every sibling we know of, and the verdict does not
            // consult this flag for that audience — passed for the shape, not for the decision.
            peerDeviceSetIsComplete: true
        ).verdict == .foreign {
            Log.debug(
                "SENDER_SYNC: \(message.id) is addressed to another of our devices — skipping",
                category: "MessageRouter"
            )
            PersistentACKStore.shared.markProcessed(message.id, senderId: message.from)
            return
        }

        // The copy's certificate names the device that wrote it, and that one session is read:
        // the message says which state it means (todo/254). The certificate is not checked on an
        // existing session, so it is only a name; opening on that session is what proves the writer
        // holds it, and the check below is what makes that session one of ours. A copy that names
        // nobody opens nothing. Until 2026-11-07 such a copy walked every sibling's session.
        let origin = SenderSyncOrigin.of(
            certifiedAccount: message.senderCertificate?.userId,
            device: message.senderCertificate?.deviceId,
            myUserId: currentUserId,
            myDeviceId: AuthSessionManager.shared.currentDeviceId,
            accountOfDevice: { SessionAddressing.peer(ofDevice: $0)?.accountId }
        )
        let device: String
        switch origin {
        case .device(let named):
            device = named
        case .unnamed:
            Log.error("SENDER_SYNC: \(message.id.prefix(8))… carries no certificate, nothing names its session — dropping", category: "MessageRouter")
            PerformanceMetrics.shared.record(.senderSyncUnroutable, label: "no_certificate")
            return
        case .notOurs:
            // Read, a contact's profile or card would be applied as our own.
            Log.error("SENDER_SYNC: \(message.id.prefix(8))… names a device that is not ours — dropping", category: "MessageRouter")
            PerformanceMetrics.shared.record(.senderSyncUnroutable, label: "not_our_device")
            return
        }
        guard let opened = openSenderSync(message, device: device) else {
            handleUnopenedSenderSync(message, in: context, myUserId: currentUserId)
            return
        }

        routeOpenedSenderSync(opened.plaintext, original: message, myUserId: currentUserId, in: context)
    }

    /// Reassemble → strip the routing header → save. The one implementation of what happens to a
    /// SENDER_SYNC once it is open, so the session-already-existed path and the
    /// session-established-just-now path cannot come to differ.
    ///
    /// `assemble` stops before content decoding on purpose: the header has to come off in between,
    /// and it is only present once in a reassembled multi-chunk stream — see `SenderSyncRouting`.
    private func routeOpenedSenderSync(
        _ plaintext: Data,
        original: ChatMessage,
        myUserId: String,
        in context: NSManagedObjectContext
    ) {
        // Read markers ride the same own-device envelope; the frame inside says which. Opened by
        // a session with one of our own devices (`SenderSyncOrigin`), so they are ours.
        if let frame = ChunkedMessageCodec.controlFrame(plaintext),
           ContentTypeRouting.framedSideChannel(for: frame.contentType) == .readSync {
            applyReadMarkers(frame.payload, myUserId: myUserId, fromOwnAccount: true)
            return
        }
        // The account's intake key from one of our devices — same envelope, same one check.
        if let frame = ChunkedMessageCodec.controlFrame(plaintext),
           ContentTypeRouting.framedSideChannel(for: frame.contentType) == .contactCard {
            if let card = ContactCardPayload.read(frame.payload), let key = card.intakeKey {
                IntakeCredentialService.shared.receiveOwnKeyFromSibling(
                    IntakeKeyState(generation: card.intakeGeneration, key: key)
                )
            } else {
                Log.error("SENDER_SYNC: own contact card did not decode", category: "MessageRouter")
            }
            return
        }
        // Our name and avatar from one of our own devices. A contact's profile arrives as their
        // message and is applied to their row; this one was opened by a session with a device of
        // ours, so it is our profile and belongs on our row. It is not a chat message.
        if let frame = ChunkedMessageCodec.controlFrame(plaintext),
           ContentTypeRouting.framedSideChannel(for: frame.contentType) == .profile {
            if let profile = ProfileShare.read(frame.payload) {
                ProfileSharingManager.shared.applyOwnProfile(profile, accountId: myUserId)
            } else {
                Log.error("SENDER_SYNC: own profile did not decode", category: "MessageRouter")
            }
            return
        }
        switch chunkReassembler.assemble(data: plaintext, senderId: original.from) {
        case .incomplete:
            Log.debug("SENDER_SYNC: chunk incomplete — waiting for more", category: "MessageRouter")
        case .invalid(let reason):
            Log.error("SENDER_SYNC: framing invalid for \(original.id): \(reason)", category: "MessageRouter")
        case .notFramed(let raw):
            saveSenderSyncFromRouted(raw, original: original, myUserId: myUserId, in: context)
        case .complete(let assembled, let e2eMessageId):
            saveSenderSyncFromRouted(
                assembled,
                original: original,
                myUserId: myUserId,
                e2eMessageId: e2eMessageId,
                in: context
            )
        }
    }

    /// Markers from another device of ours: move each partner's boundary if later, and let the
    /// chat's unread count down to what the boundary leaves.
    func applyReadMarkers(
        _ payload: Data, myUserId: String, fromOwnAccount: Bool, boundaries: ReadBoundaries = .shared
    ) {
        guard let markers = ReadSync.decode(payload) else {
            Log.error("ReadSync: markers did not decode", category: "MessageRouter")
            return
        }
        for (partner, boundary) in markers where partner != myUserId.lowercased() {
            let held = boundaries.boundary(for: partner)
            guard ReadSync.outcome(of: boundary, held: held, fromOwnAccount: fromOwnAccount) == .apply,
                  boundaries.advance(partner, to: boundary),
                  let chat = try? LocalRepositories.chats.chat(withPeer: partner) else { continue }
            let left = ReadSync.unreadLeft(
                inChat: chat.id, unread: chat.unreadCount, boundary: boundary, messages: LocalRepositories.messages
            )
            if left != chat.unreadCount { _ = try? LocalRepositories.chats.setUnread(chat.id, left) }
            // Read there: the banner this device already showed for the chat is stale (owner,
            // 2026-10-19 — writing on the Desktop, the phone kept the banners).
            if left == 0 { LocalNotificationManager.shared.withdrawChatBanner(chatId: chat.id) }
            LocalNotificationManager.shared.syncBadge()
            Log.info("ReadSync: \(partner.prefix(8))… read on another device — unread \(chat.unreadCount) → \(left)", category: "MessageRouter")
        }
    }

    /// Strip the routing header, then hand the content to the ordinary decoder.
    private func saveSenderSyncFromRouted(
        _ assembled: Data,
        original: ChatMessage,
        myUserId: String,
        e2eMessageId: String? = nil,
        in context: NSManagedObjectContext
    ) {
        guard let (routing, content) = SenderSyncRouting.decode(prefixOf: assembled) else {
            // No header: the sender is running a build from before this existed, and nothing in
            // the delivery says which conversation the copy belongs to. Same outcome as every
            // SENDER_SYNC before this change, and the same message.
            legacySenderSyncUnroutable(original)
            return
        }
        guard routing.partnerUserId != myUserId else {
            Log.error(
                "SENDER_SYNC: routing header names ourselves as the partner for \(original.id) — dropping",
                category: "MessageRouter"
            )
            return
        }
        saveSenderSyncMessage(
            content,
            original: original,
            partnerUserId: routing.partnerUserId,
            e2eMessageId: e2eMessageId,
            in: context
        )
    }

    /// A sync we could open but cannot place: the sender did not send a routing header.
    ///
    /// This was every SENDER_SYNC before 2026-08-17. `buildEnvelope` sets `conversationID` and
    /// `senderDevice` on every non-sealed envelope and SENDER_SYNC is never sealed, but the server
    /// blanks both on delivery **on purpose** (`messaging-service/src/envelope.rs`:
    /// `sender_device: None`, and "conversation_id is intentionally empty: it is server-visible
    /// metadata and must not carry E2E semantics"). Observed 2026-08-05, one message id on both
    /// sides of a single account:
    ///
    ///     sent      1aa6abac…-ss-b3ed60ab  conversationId = direct:0a1c609f…:ea134859…
    ///     received  conversationId = ''    senderDevice = ''
    ///
    /// The message routed on metadata the server is designed never to deliver — a design
    /// contradiction rather than a relay bug. It is now carried inside the ciphertext, so this path
    /// means only "the other device is on an older build".
    private func legacySenderSyncUnroutable(_ message: ChatMessage) {
        Log.error(
            "SENDER_SYNC: no routing header in \(message.id) — the sending device predates the header, and conversationId is blanked by the server by design, so this copy cannot be placed in a conversation.",
            category: "MessageRouter"
        )
        PerformanceMetrics.shared.record(.senderSyncUnroutable, label: "no_routing_header")
    }

    /// Read the copy on the session with the device it names.
    private func openSenderSync(_ message: ChatMessage, device: String) -> (plaintext: Data, contactId: String)? {
        guard CryptoManager.shared.hasSession(for: device) else { return nil }
        guard let result = try? CryptoManager.shared.decryptMessage(message, contactIdOverride: device)
        else { return nil }
        return (result.plaintext, device)
    }

    /// The named session did not open it. A message carrying the handshake header is the one
    /// recoverable case: the sibling opened a new state — or its first — and this opens it, with
    /// the key the certificate names, nothing fetched
    /// (`decisions/first-message-opens-without-the-server.md`).
    private func handleUnopenedSenderSync(
        _ message: ChatMessage,
        in context: NSManagedObjectContext,
        myUserId: String
    ) {
        guard message.initKind == .handshake else {
            Log.error(
                "SENDER_SYNC: the session it names did not open \(message.id) and it carries no handshake header (messageNumber=\(message.messageNumber)) — dropping",
                category: "MessageRouter"
            )
            // Counted, like the branch below. This is the *more common* way to be unroutable —
            // it is what a device does with every sync after losing the session, and until
            // 2026-08-30 losing it was routine, because the restore read the chat list and an
            // own-device session has no chat. The release gate is `sender_sync_unroutable` at
            // zero on a three-device run, and the commonest path to non-zero was not counted.
            PerformanceMetrics.shared.record(.senderSyncUnroutable, label: "no_session_and_not_first")
            return
        }
        if openSenderSync(firstMessage: message, myUserId: myUserId, in: context) { return }

        // Say so: an unroutable transcript copy that leaves no trace is indistinguishable from one
        // that never arrived.
        Log.error("SENDER_SYNC: \(message.id.prefix(8))… opened no session — dropping", category: "MessageRouter")
        PerformanceMetrics.shared.record(.senderSyncUnroutable, label: "no_own_device_session")
    }

    // `extractPartnerUserId(from:myUserId:)` was removed 2026-08-17 with its only caller. It read
    // the partner out of `Envelope.conversation_id`, which the server blanks on delivery by
    // design, so it returned "" for every SENDER_SYNC ever received. The partner now travels
    // inside the ciphertext — see `SenderSyncRouting`.

    /// Save a decrypted SENDER_SYNC message as an outgoing bubble.
    ///
    /// Wire payload is the same binary path as a normal receive (KNST → MessageContent).
    /// Local store uses CTM1 `storagePayload` when the reassembler provides it (C1c).
    /// - Parameters:
    ///   - content: the message content with its routing header already removed, and already
    ///     reassembled — the caller had to split those two steps to reach the header, so this must
    ///     not run the framing again.
    ///   - e2eMessageId: the sender's message id from the KNST header, carried over from `assemble`.
    func saveSenderSyncMessage(
        _ content: Data,
        original: ChatMessage,
        partnerUserId: String,
        e2eMessageId: String?,
        in context: NSManagedObjectContext
    ) {
        // Decode wire bytes through the same pipeline as inbound chat messages.
        let storagePayload: Data
        let e2eRowId: String?
        let mediaAlbum: Shared_Proto_Messaging_V1_MediaAlbumMessage?
        var reply: (messageId: String, quote: String?)?

        switch ChunkedMessageReassembler.shared.decodeAssembled(content, e2eMessageId: e2eMessageId) {
        case .assembled(let text, let quoted, let e2eId, let album, let storage):
            e2eRowId = e2eId
            mediaAlbum = album
            // A reply sent from a sibling is a reply here too. Until 2026-10-20 the quote was
            // dropped on this path and the row went in with no strip (TODO 177).
            reply = Self.replyContext(from: quoted)
            if let storage, !storage.isEmpty {
                storagePayload = storage
            } else {
                storagePayload = LocalMessagePayload.encodeText(text)
            }
        case .legacy(let text):
            e2eRowId = nil
            mediaAlbum = nil
            storagePayload = LocalMessagePayload.encodeText(text)
        case .profile:
            Log.info("SENDER_SYNC: profile-share carrier, not persisting as text", category: "MessageRouter")
            return
        case .edit:
            Log.info("SENDER_SYNC: edit in sync payload, ignoring", category: "MessageRouter")
            return
        case .reaction(let targetMessageID, let emoji, let action, let timestampMs):
            let decision = Reactions.applyIncoming(
                targetMessageId: targetMessageID,
                reactorUserId: original.from,
                actionRawValue: action.rawValue,
                emoji: emoji,
                payloadTimestampMs: timestampMs,
                fallbackTimestampMs: Reactions.envelopeTimestampMs(original.timestamp),
                nowMs: Int64(Date().timeIntervalSince1970 * 1000)
            )
            Log.info(
                "SENDER_SYNC: reaction on \(targetMessageID.prefix(8))… \(decision) — not a chat row",
                category: "MessageRouter"
            )
            return
        case .incomplete:
            // Unreachable: reassembly finished before the caller stripped the routing header.
            // Kept because the result type is shared with `process`.
            Log.error("SENDER_SYNC: decoder reported incomplete on assembled bytes", category: "MessageRouter")
            return
        case .invalid:
            Log.info(
                "SENDER_SYNC: could not decode payload for \(partnerUserId.prefix(8))… — no user content",
                category: "MessageRouter"
            )
            return
        }

        // Typed session-control content types (should not appear as SENDER_SYNC body).
        if SessionControlCodec.op(forContentType: Int(original.contentType)) != nil {
            return
        }

        // Canonical row id: E2E id from KNST when present, else strip multi-device wire suffixes
        // (`-ss-…`, `-ss-…-cN`) so edits/receipts still match the originating device's message id.
        let rowId = Self.incomingRowId(e2eMessageId: e2eRowId, wireMessageId: original.id)

        do {
            if let existing = try LocalRepositories.messages.message(rowId) {
                if existing.fromUserId == original.from {
                    // The same row the regular receive path would refresh, the same way — until
                    // 2026-10-20 this path took only the order key and left a row stored
                    // undecryptable empty (TODO 181).
                    try Self.refreshExistingRow(existing, serverOrderKey: original.serverOrderKey, body: storagePayload)
                } else {
                    Log.error("SENDER_SYNC: \(rowId.prefix(8))… is another author's row — not overwritten", category: "MessageRouter")
                }
                return // already saved (duplicate delivery / other chunk path)
            }
        } catch {
            Log.error("SENDER_SYNC: failed to deduplicate message \(rowId.prefix(8))…: \(error)", category: "MessageRouter")
            return
        }

        if let mediaAlbum {
            MediaWireCodec.receiveAlbum(mediaAlbum, for: rowId)
        }
        let timestamp = Date.fromRemoteTimestamp(original.timestamp)
        let chatId: String
        do {
            chatId = try Self.chatId(forPeer: partnerUserId)
            try LocalRepositories.messages.insert(MessageRecord(
                id: rowId, chatId: chatId, fromUserId: original.from, toUserId: partnerUserId,
                isSentByMe: true, timestamp: timestamp,
                orderKey: original.serverOrderKey
                    ?? ServerMessageOrder.local(timestamp: timestamp, messageId: rowId),
                body: storagePayload, contentType: .regular, deliveryStatus: .sent, retryCount: 0,
                suiteId: 0, isEdited: false, editedAt: nil,
                replyToMessageId: reply?.messageId, replyQuote: reply?.quote,
                transcript: nil, transcriptLanguage: nil, transcriptGeneratedAt: nil
            ), searchText: LocalMessagePayload.decode(storagePayload).plainText)
        } catch {
            Log.error("SENDER_SYNC: message \(rowId.prefix(8))… not saved: \(error)", category: "MessageRouter")
            return
        }
        MessagePersistenceService.refreshPreview(ofChat: chatId)

        if !original.senderDeviceId.isEmpty {
            CryptoManager.shared.saveSessionToKeychain(
                forDevice: original.senderDeviceId
            )
        }
        Log.info("SENDER_SYNC: saved outgoing message in conversation with \(partnerUserId.prefix(8))…", category: "MessageRouter")
    }

    /// Open the session a sibling's SENDER_SYNC arrived on, from the copy itself, then route it.
    /// False when it did not open.
    private func openSenderSync(
        firstMessage message: ChatMessage,
        myUserId: String,
        in context: NSManagedObjectContext
    ) -> Bool {
        do {
            let opened = try CryptoManager.shared.openReceiving(singleMessage: message)
            routeOpenedSenderSync(opened.plaintext, original: message, myUserId: myUserId, in: context)

            // Replenish any OTPKs consumed during this session init
            Task {
                let deviceId = KeychainManager.shared.loadDeviceID() ?? ""
                await OtpkReplenishmentService.replenishIfNeeded(deviceId: deviceId)
            }
            return true
        } catch {
            Log.error("SENDER_SYNC: opening \(message.id.prefix(8))… failed: \(error)", category: "MessageRouter")
            return false
        }
    }
}
