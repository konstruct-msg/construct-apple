//
//  MessageBubble+View.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import SwiftUI

extension MessageBubble {
    var body: some View {
        Group {
            // Guard against accessing a deleted or faulted Core Data object.
            // This can happen when a placeholder is deleted while SwiftUI still
            // holds a stale reference to it (between FRC delete notification and
            // the next SwiftUI layout pass).
            if message.isDeleted || message.managedObjectContext == nil {
                EmptyView()
            } else if message.fromUserId == "SYSTEM" {
                // A SYSTEM row with no resolvable text has nothing to show — render
                // nothing instead of a literal "System message" placeholder. These
                // appeared when an ephemeral control message leaked into the transcript
                // or its at-rest content key was briefly unreadable (see MessageKeyStore).
                if message.displayText.isEmpty {
                    EmptyView()
                } else {
                    MessageBubbleSystemView(content: message.displayText)
                }
            } else if message.displayText.hasPrefix("[SYSTEM]") {
                MessageBubbleSystemView(
                    content: message.displayText
                        .replacingOccurrences(of: "[SYSTEM]", with: "")
                        .trimmingCharacters(in: .whitespaces)
                )
            } else {
                MessageBubbleRegularView(
                    message: message,
                    isLastInGroup: isLastInGroup,
                    isSelected: isSelected,
                    isEditMode: isEditMode,
                    containerWidth: containerWidth,
                    onRetry: onRetry,
                    onReply: onReply,
                    onDelete: onDelete,
                    onSelect: onSelect,
                    onEnterSelectMode: onEnterSelectMode,
                    onTapMedia: onTapMedia,
                    onEdit: onEdit,
                    onReplyWithQuote: onReplyWithQuote
                )
            }
        }
    }
}

