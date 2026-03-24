//
//  MessageBubble+View.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

extension MessageBubble {
    var body: some View {
        // Guard against accessing a deleted or faulted Core Data object.
        // This can happen when a placeholder is deleted while SwiftUI still
        // holds a stale reference to it (between FRC delete notification and
        // the next SwiftUI layout pass).
        guard !message.isDeleted, message.managedObjectContext != nil else {
            return AnyView(EmptyView())
        }
        // ✅ Check if this is a system message by fromUserId
        if message.fromUserId == "SYSTEM" {
            return AnyView(systemMessageView(message.decryptedContent ?? "System message"))
        } else if let content = message.decryptedContent, content.hasPrefix("[SYSTEM]") {
            // ✅ Legacy support for [SYSTEM] prefix
            return AnyView(systemMessageView(content.replacingOccurrences(of: "[SYSTEM]", with: "").trimmingCharacters(in: .whitespaces)))
        } else {
            return AnyView(regularMessageView)
        }
    }

    // MARK: - System Message View

    private func systemMessageView(_ content: String) -> some View {
        HStack {
            Spacer()
            Text(content)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(12)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Regular Message View

    private var regularMessageView: some View {
        HStack(spacing: 8) {
            // Selection checkbox in edit mode - positioned based on message direction
            if isEditMode && !message.isSentByMe {
                // Checkbox on LEFT for incoming messages
                Button {
                    onSelect?(message)
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(isSelected ? Color.blue : .gray)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }

            if message.isSentByMe {
                Spacer(minLength: 60)
            }

            VStack(alignment: message.isSentByMe ? .trailing : .leading, spacing: 4) {
                // ✅ Check if this is a profile share message
                if let content = message.decryptedContent,
                   let profileData = parseProfileMessage(content)
                {
                    // Display profile card
                    ProfileShareBubbleView(profileData: profileData)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
                        )
                }
                // ✅ Check if this is a media message
                else if let mediaContent = parseMediaMessage(message.decryptedContent) {
                    // Display media message without bubble - just rounded corners
                    VStack(alignment: .leading, spacing: 0) {
                        replyIndicatorView
                        MediaMessageView(
                            mediaContent: mediaContent,
                            message: message,
                            isSelected: isSelected,
                            onTapFullScreen: { onTapMedia?(message) }
                        )
                    }
                }
                // ✅ Check if this is a file attachment message
                else if let fileContent = parseFileMessage(message.decryptedContent) {
                    VStack(alignment: .leading, spacing: 0) {
                        replyIndicatorView
                        FileAttachmentBubbleView(fileContent: fileContent, isSentByMe: message.isSentByMe)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
                            )
                    }
                } else {
                    // Text message bubble: reply indicator lives INSIDE the bubble background
                    // so the quote block and the message text share one visual container.
                    VStack(alignment: .leading, spacing: 0) {
                        // Reply quote at the top of the bubble (if present)
                        replyIndicatorView

                        VStack(alignment: .leading, spacing: 4) {
                            // Main message content
                            if message.decryptedContent == nil {
                                // Irrecoverable: message was saved when the session was unavailable
                                // or decryption failed. Display a clear unavailable indicator.
                                HStack(spacing: 5) {
                                    Image(systemName: "lock.trianglebadge.exclamationmark")
                                        .font(.caption)
                                    Text(NSLocalizedString("message_unavailable", comment: ""))
                                        .italic()
                                }
                                .font(.callout)
                                .foregroundColor(.secondary)
                            } else {
                                LinkDetectingText(
                                    message.decryptedContent!,
                                    color: message.isSentByMe ? .white : .primary
                                )
                            }
                        }
                        .padding(.horizontal, 12)
                        // Reduce top padding when reply bar is shown — it already provides spacing.
                        .padding(.top, message.replyToContent != nil ? 4 : 8)
                        .padding(.bottom, 8)
                    }
                    #if canImport(UIKit)
                    .background(
                        isSelected
                            ? (message.isSentByMe ? Color.accentColor.opacity(0.75) : Color.accentColor.opacity(0.15))
                            : (message.isSentByMe ? Color.accentColor : Color(uiColor: .systemGray5))
                    )
                    #else
                    .background(
                        isSelected
                            ? (message.isSentByMe ? Color.accentColor.opacity(0.75) : Color.accentColor.opacity(0.15))
                            : (message.isSentByMe ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                    )
                    #endif
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }

                if isLastInGroup {
                    HStack(spacing: 4) {
                        if message.isSentByMe {
                            deliveryStatusView
                        }

                        if message.isEdited {
                            Text(NSLocalizedString("edited", comment: ""))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        Text(message.timestamp, style: .time)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 4)
                }
            }
            .frame(maxWidth: containerWidth * 0.7, alignment: message.isSentByMe ? .trailing : .leading)
            .contentShape(.interaction, Rectangle())
            #if os(iOS)
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 8))
            #endif
            .onTapGesture {
                if isEditMode {
                    onSelect?(message)
                }
            }
            .contextMenu {
                if !isEditMode {
                    if let onReply {
                        Button {
                            onReply(message)
                        } label: {
                            Label("reply", systemImage: "arrowshape.turn.up.left")
                        }
                    }

                    // "Quote & Reply" — only for plain text messages
                    if let onReplyWithQuote,
                       let content = message.decryptedContent,
                       parseMediaContent(from: content) == nil,
                       parseFileMessage(content) == nil
                    {
                        Button {
                            onReplyWithQuote(message, content)
                        } label: {
                            Label(NSLocalizedString("quote_reply", comment: ""), systemImage: "text.quote")
                        }
                    }

                    if message.isSentByMe,
                       message.decryptedContent != nil,
                       !message.decryptedContent!.hasPrefix("[MEDIA]"),
                       !message.decryptedContent!.hasPrefix("[FILE]"),
                       let onEdit
                    {
                        Button {
                            onEdit(message)
                        } label: {
                            Label(NSLocalizedString("edit_message", comment: ""), systemImage: "pencil")
                        }
                    }

                    Button {
                        PlatformClipboard.copy(message.decryptedContent ?? "")
                    } label: {
                        Label("copy", systemImage: "doc.on.doc")
                    }

                    if let onEnterSelectMode {
                        Button {
                            onEnterSelectMode(message)
                        } label: {
                            Label("select_messages", systemImage: "checkmark.circle")
                        }
                    }

                    Divider()

                    if let onDelete {
                        Button(role: .destructive) {
                            onDelete(message)
                        } label: {
                            Label("delete", systemImage: "trash")
                        }
                    }

                    if (message.deliveryStatus == .failed || message.deliveryStatus == .queued),
                       let onRetry
                    {
                        Button {
                            onRetry(message)
                        } label: {
                            Label("retry", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }
            // Swipe-to-reply: right swipe triggers onReply when not in edit mode
            .offset(x: swipeOffset)
            .gesture(
                isEditMode ? nil : DragGesture(minimumDistance: 20, coordinateSpace: .local)
                    .onChanged { value in
                        let h = value.translation.width
                        let v = abs(value.translation.height)
                        guard h > 0, h > v else { return }
                        swipeOffset = min(h * 0.5, 60)
                    }
                    .onEnded { _ in
                        if swipeOffset >= 40 {
                            onReply?(message)
                            #if canImport(UIKit)
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            #endif
                        }
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            swipeOffset = 0
                        }
                    }
            )
            .overlay(alignment: message.isSentByMe ? .leading : .trailing) {
                if swipeOffset > 10 {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.accentColor)
                        .opacity(min(max(Double(swipeOffset / 40), 0), 1))
                        .offset(x: message.isSentByMe ? -swipeOffset - 8 : swipeOffset + 8)
                        .animation(.interactiveSpring(), value: swipeOffset)
                }
            }

            if !message.isSentByMe {
                Spacer(minLength: 60)
            }

            // Selection checkbox in edit mode - positioned based on message direction
            if isEditMode && message.isSentByMe {
                Button {
                    onSelect?(message)
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(isSelected ? Color.blue : .gray)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var deliveryStatusView: some View {
        let status = message.deliveryStatus

        switch status {
        case .sending:
            // Uploading — outline circle, message in transit
            Circle()
                .stroke(Color.secondary.opacity(0.5), lineWidth: 1.5)
                .frame(width: 10, height: 10)

        case .sent:
            // Server acknowledged — filled gray circle
            Circle()
                .fill(Color.secondary.opacity(0.6))
                .frame(width: 10, height: 10)

        case .delivered:
            // Delivered to recipient — filled StillGreen circle
            Circle()
                .fill(Color.green)
                .frame(width: 10, height: 10)

        case .queued:
            Button {
                if let onRetry {
                    onRetry(message)
                }
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "tray")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Text("retry")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }

        case .failed:
            Button {
                if let onRetry {
                    onRetry(message)
                }
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                    Text("retry")
                        .font(.caption2)
                        .foregroundColor(.red)
                }
            }
        }
    }

    // MARK: - Media Message Parsing

    private func parseProfileMessage(_ content: String) -> ProfileShareData? {
        guard let data = content.data(using: .utf8) else { return nil }

        // Check if it looks like a profile message
        if let jsonDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = jsonDict["type"] as? String,
           type == "profile"
        {
            // Try to decode it properly
            return try? JSONDecoder().decode(ProfileShareData.self, from: data)
        }
        return nil
    }

    private func parseMediaMessage(_ content: String?) -> MediaMessageContent? {
        parseMediaContent(from: content)
    }

    private func parseFileMessage(_ content: String?) -> FileMessageContent? {
        guard let content,
              let data = content.data(using: .utf8),
              let json = try? JSONDecoder().decode(FileMessageContent.self, from: data),
              json.type == "file"
        else { return nil }
        return json
    }

    /// Reply context bar shown above message content, rendered INSIDE the bubble background.
    @ViewBuilder
    private var replyIndicatorView: some View {
        if let replyContent = message.replyToContent {
            HStack(spacing: 4) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.6))
                    .frame(width: 3)

                ReplyPreviewContent(
                    content: replyContent,
                    messageId: message.replyToMessageId,
                    thumbnailSize: 40,
                    lineLimit: 2
                )
                .padding(.vertical, 4)
                .padding(.trailing, 4)
            }
            // Match the bubble's horizontal padding so the accent bar aligns with the message text.
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
    }
}

