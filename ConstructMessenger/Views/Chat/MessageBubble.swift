//
//  MessageBubble.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import SwiftUI

struct MessageBubble: View {
    /// Observed so the view re-renders when deliveryStatusRaw (or any @NSManaged property) changes.
    /// NSManagedObject conforms to ObservableObject via KVO, so SwiftUI subscribes automatically.
    let message: TranscriptRow
    let isLastInGroup: Bool
    let isSelected: Bool
    let isEditMode: Bool
    let onRetry: ((TranscriptRow) -> Void)?
    let onReply: ((TranscriptRow) -> Void)?
    let onDelete: ((TranscriptRow) -> Void)?
    let onSelect: ((TranscriptRow) -> Void)?
    let onEnterSelectMode: ((TranscriptRow) -> Void)?
    /// Media open — second argument is the album tile index (0 for single-item).
    let onTapMedia: ((TranscriptRow, Int) -> Void)?
    let onEdit: ((TranscriptRow) -> Void)?
    /// Called when the user chooses "Quote & Reply" — provides the message and the selected quote text.
    let onReplyWithQuote: ((TranscriptRow, String) -> Void)?
    /// Tap on the in-bubble reply strip — jump to the parent message and soft-focus the pair.
    let onJumpToReply: ((TranscriptRow) -> Void)?
    /// Double-tap like / badge tap. Second argument is the emoji (`ReactionReducer.likeEmoji` on double-tap).
    let onReact: ((TranscriptRow, String) -> Void)?
    /// "Forward" — the host asks where to (`ForwardPickerView`).
    let onForward: ((TranscriptRow) -> Void)?

    @Environment(\.containerWidth) var containerWidth

    init(
        message: TranscriptRow,
        isLastInGroup: Bool = true,
        isSelected: Bool = false,
        isEditMode: Bool = false,
        onRetry: ((TranscriptRow) -> Void)? = nil,
        onReply: ((TranscriptRow) -> Void)? = nil,
        onDelete: ((TranscriptRow) -> Void)? = nil,
        onSelect: ((TranscriptRow) -> Void)? = nil,
        onEnterSelectMode: ((TranscriptRow) -> Void)? = nil,
        onTapMedia: ((TranscriptRow, Int) -> Void)? = nil,
        onEdit: ((TranscriptRow) -> Void)? = nil,
        onReplyWithQuote: ((TranscriptRow, String) -> Void)? = nil,
        onJumpToReply: ((TranscriptRow) -> Void)? = nil,
        onReact: ((TranscriptRow, String) -> Void)? = nil,
        onForward: ((TranscriptRow) -> Void)? = nil
    ) {
        self.message = message
        self.isLastInGroup = isLastInGroup
        self.isSelected = isSelected
        self.isEditMode = isEditMode
        self.onRetry = onRetry
        self.onReply = onReply
        self.onDelete = onDelete
        self.onSelect = onSelect
        self.onEnterSelectMode = onEnterSelectMode
        self.onTapMedia = onTapMedia
        self.onEdit = onEdit
        self.onReplyWithQuote = onReplyWithQuote
        self.onJumpToReply = onJumpToReply
        self.onReact = onReact
        self.onForward = onForward
    }
}
