//
//  MessageReplyEditBar.swift
//  Construct Messenger
//
//  Reply preview bar and edit-mode banner shown above the message input field.
//

import SwiftUI
import Combine

// MARK: - Reply Bar

struct MessageReplyBar: View {
    let content: String?
    let messageId: String?
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(Color.CT.accent)
                .frame(width: 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey("reply_to_colon"))
                    .font(CTFont.regular(10))
                    .foregroundColor(Color.CT.textDim)
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
                Image(systemName: "xmark.circle")
                    .font(CTFont.regular(13))
                    .foregroundColor(Color.CT.textDim)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxHeight: 50)
        .background(Color.CT.bgMsg)
        .overlay(alignment: .bottom) {
            Rectangle().frame(height: 0.5).foregroundColor(Color.CT.noise)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - Edit Bar

struct MessageEditBar: View {
    let content: String
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(Color.CT.accentDim)
                .frame(width: 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey("editing_message"))
                    .font(CTFont.regular(10))
                    .foregroundColor(Color.CT.accentDim)
                Text(content)
                    .font(CTFont.regular(13))
                    .lineLimit(1)
                    .foregroundColor(Color.CT.textDim)
            }
            .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Button(action: onCancel) {
                Image(systemName: "xmark.circle")
                    .font(CTFont.regular(13))
                    .foregroundColor(Color.CT.textDim)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxHeight: 50)
        .background(Color.CT.bgMsg)
        .overlay(alignment: .bottom) {
            Rectangle().frame(height: 0.5).foregroundColor(Color.CT.noise)
        }
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
