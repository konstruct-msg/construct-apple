//
//  CallTranscript.swift
//  Construct Messenger
//
//  A call shows in the conversation it was with, between the messages, at the time it started:
//  "Missed call", "Outgoing call · 3:05", and a tap calls back. Until 2026-11-26 a call was only a
//  row of the call log, seen on the Recents tab; the owner never opened that tab, and a missed call
//  without it was a missed call nobody saw (vault todo 351).
//
//  Signal keeps a call the same way, as an interaction of the thread (`TSCall`). Here the
//  transcript row is a pointer: its id names the log's record (`call-<call id>`), its body is
//  empty, and what the call was — direction, outcome, length — is read from the log, the one place
//  it is written. The row is local and never sent; the other side writes its own.
//

import Foundation

enum CallTranscript {

    /// The transcript row of a call: one per call, so a second write of the same call adds nothing.
    static func messageId(callId: String) -> String { idPrefix + callId.lowercased() }

    /// The call a row of type `.call` names.
    static func callId(ofMessage messageId: String) -> String? {
        let id = messageId.lowercased()
        guard id.hasPrefix(idPrefix), id.count > idPrefix.count else { return nil }
        return String(id.dropFirst(idPrefix.count))
    }

    private static let idPrefix = "call-"

    /// When the call stands in the transcript: when it started; a call with no start, when it ended.
    static func time(of call: CallRecord) -> Date {
        call.startedAt ?? call.endedAt ?? Date(timeIntervalSince1970: 0)
    }

    /// The row for `call` in `chatId`. `ownUserId` is this account (`ServerUserId`). Fields a call
    /// has no use for (reply, edit, transcript, suite) are left empty on purpose.
    static func row(for call: CallRecord, chatId: String, ownUserId: String) -> MessageRecord {
        let id = messageId(callId: call.id)
        let outgoing = call.direction == .outgoing
        let at = time(of: call)
        return MessageRecord(
            id: id, chatId: chatId,
            fromUserId: outgoing ? ownUserId : call.peerUserId,
            toUserId: outgoing ? call.peerUserId : ownUserId,
            isSentByMe: outgoing,
            timestamp: at,
            orderKey: ServerMessageOrder.local(timestamp: at, messageId: id),
            body: Data(),
            contentType: .call,
            deliveryStatus: .delivered,
            retryCount: 0, suiteId: 0, isEdited: false, editedAt: nil,
            replyToMessageId: nil, replyQuote: nil,
            transcript: nil, transcriptLanguage: nil, transcriptGeneratedAt: nil
        )
    }

    /// Whether the call counts as unread in its chat: one that rang here and nobody answered.
    static func raisesUnread(_ call: CallRecord) -> Bool {
        call.direction == .incoming && call.status == .missed
    }

    /// What the row and the chat list say, without the length.
    static func label(for call: CallRecord) -> String {
        NSLocalizedString(labelKey(for: call), comment: "")
    }

    static func labelKey(for call: CallRecord) -> String {
        switch (call.status, call.direction) {
        case (.missed, .incoming): return "call_row_missed"
        case (.missed, .outgoing): return "call_row_unanswered"
        case (.declined, _): return "call_row_declined"
        case (.failed, _): return "call_row_failed"
        case (.completed, .incoming): return "call_row_incoming"
        case (.completed, .outgoing): return "call_row_outgoing"
        }
    }

    /// The label with the length of a call that took place: "Outgoing call · 3:05".
    static func summary(for call: CallRecord) -> String {
        guard call.status == .completed, let length = call.formattedDuration else { return label(for: call) }
        return "\(label(for: call)) · \(length)"
    }

    /// Writes the call's row into `chatId`, or the chat with its peer — opened if there is none.
    /// `announce`: the call just ended here — the chat list shows it and a missed one counts as
    /// unread. A history import does not announce: those calls are old news, and the import sets
    /// the previews itself. Returns whether the row was added.
    @discardableResult
    static func write(
        _ call: CallRecord, announce: Bool, ownUserId: String, chatId: String? = nil,
        messages: any MessageStore = LocalRepositories.messages,
        chats: any ChatStore = LocalRepositories.chats
    ) throws -> Bool {
        let chatId = try chatId ?? chats.openChat(withPeer: call.peerUserId, now: nil).chat.id
        let added = try messages.insert(row(for: call, chatId: chatId, ownUserId: ownUserId), searchText: nil)
        guard added, announce else { return added }
        try chats.setPreview(chatId, text: Chat.formatPreviewText(label(for: call)), time: time(of: call))
        if raisesUnread(call) { try chats.incrementUnread(chatId) }
        return added
    }

    /// What the chat list shows for a call row, read from the log; nil when the row names no
    /// logged call.
    static func preview(of message: MessageRecord, calls: any CallStore = LocalRepositories.calls) -> String? {
        guard message.contentType == .call, let callId = callId(ofMessage: message.id),
              let call = try? calls.call(callId) else { return nil }
        return label(for: call)
    }
}

extension CallStore {
    /// The logged call `id`, or nil. The log is short (one row per call) and read whole.
    func call(_ id: String) throws -> CallRecord? {
        let wanted = id.lowercased()
        return try calls(limit: Int(Int32.max)).first { $0.id.lowercased() == wanted }
    }
}
