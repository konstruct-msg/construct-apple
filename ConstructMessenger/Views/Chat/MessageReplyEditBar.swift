//
//  MessageReplyEditBar.swift
//  Construct Messenger
//
//  Reply preview bar and edit-mode banner shown above the message input field.
//

import SwiftUI

// MARK: - Reply Bar

struct MessageReplyBar: View {
    let content: String?
    let messageId: String?
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(Color.blue)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text("reply_to_colon")
                    .font(.caption)
                    .foregroundColor(.secondary)
                ReplyPreviewContent(
                    content: content,
                    messageId: messageId,
                    thumbnailSize: 36,
                    lineLimit: 1
                )
            }
            .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
                    .font(.title3)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxHeight: 50)
        #if canImport(UIKit)
        .background(Color(uiColor: .systemGray6))
        #else
        .background(Color(nsColor: .windowBackgroundColor))
        #endif
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - Edit Bar

struct MessageEditBar: View {
    let content: String
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(Color.orange)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey("editing_message"))
                    .font(.caption)
                    .foregroundColor(.orange)
                Text(content)
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundColor(.primary)
            }
            .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
                    .font(.title3)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxHeight: 50)
        #if canImport(UIKit)
        .background(Color(uiColor: .systemGray6))
        #else
        .background(Color(nsColor: .windowBackgroundColor))
        #endif
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - Previews

#Preview("Reply Bar") {
    MessageReplyBar(
        content: "Hey, how are you doing today?",
        messageId: nil,
        onCancel: {}
    )
}

#Preview("Edit Bar") {
    MessageEditBar(
        content: "This is the message being edited",
        onCancel: {}
    )
}
