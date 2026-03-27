//
//  MessageBubbleRegularView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

struct MessageBubbleRegularView: View {
    /// Observed so the view re-renders when deliveryStatusRaw (or any @NSManaged property) changes.
    /// NSManagedObject conforms to ObservableObject via KVO, so SwiftUI subscribes automatically.
    @ObservedObject var message: Message

    let isLastInGroup: Bool
    let isSelected: Bool
    let isEditMode: Bool
    let containerWidth: CGFloat

    let onRetry: ((Message) -> Void)?
    let onReply: ((Message) -> Void)?
    let onDelete: ((Message) -> Void)?
    let onSelect: ((Message) -> Void)?
    let onEnterSelectMode: ((Message) -> Void)?
    let onTapMedia: ((Message) -> Void)?
    let onEdit: ((Message) -> Void)?
    let onReplyWithQuote: ((Message, String) -> Void)?

    @State private var swipeOffset: CGFloat = 0

    var body: some View {
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
                if let content = message.decryptedContent,
                   let profileData = MessageBubbleContentParsing.parseProfileMessage(content)
                {
                    ProfileShareBubbleView(profileData: profileData)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
                        )
                } else if let mediaContent = MessageBubbleContentParsing.parseMediaMessage(message.decryptedContent) {
                    VStack(alignment: .leading, spacing: 0) {
                        replyIndicatorView
                        MediaMessageView(
                            mediaContent: mediaContent,
                            message: message,
                            isSelected: isSelected,
                            onTapFullScreen: { onTapMedia?(message) }
                        )
                    }
                } else if let fileContent = MessageBubbleContentParsing.parseFileMessage(message.decryptedContent) {
                    VStack(alignment: .leading, spacing: 0) {
                        replyIndicatorView
                        FileAttachmentBubbleView(fileContent: fileContent, isSentByMe: message.isSentByMe)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
                            )
                    }
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        replyIndicatorView

                        VStack(alignment: .leading, spacing: 4) {
                            if message.decryptedContent == nil {
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

                        Text(message.safeTimestamp, style: .time)
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
                        Button { onReply(message) } label: {
                            Label("reply", systemImage: "arrowshape.turn.up.left")
                        }
                    }

                    if let onReplyWithQuote,
                       let content = message.decryptedContent,
                       parseMediaContent(from: content) == nil,
                       MessageBubbleContentParsing.parseFileMessage(content) == nil
                    {
                        Button { onReplyWithQuote(message, content) } label: {
                            Label(NSLocalizedString("quote_reply", comment: ""), systemImage: "text.quote")
                        }
                    }

                    if message.isSentByMe,
                       message.decryptedContent != nil,
                       !message.decryptedContent!.hasPrefix("[MEDIA]"),
                       !message.decryptedContent!.hasPrefix("[FILE]"),
                       let onEdit
                    {
                        Button { onEdit(message) } label: {
                            Label(NSLocalizedString("edit_message", comment: ""), systemImage: "pencil")
                        }
                    }

                    Button { PlatformClipboard.copy(message.decryptedContent ?? "") } label: {
                        Label("copy", systemImage: "doc.on.doc")
                    }

                    if let onEnterSelectMode {
                        Button { onEnterSelectMode(message) } label: {
                            Label("select_messages", systemImage: "checkmark.circle")
                        }
                    }

                    Divider()

                    if let onDelete {
                        Button(role: .destructive) { onDelete(message) } label: {
                            Label("delete", systemImage: "trash")
                        }
                    }

                    if (message.deliveryStatus == .failed || message.deliveryStatus == .queued),
                       let onRetry
                    {
                        Button { onRetry(message) } label: {
                            Label("retry", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }
            .offset(x: swipeOffset)
            .gesture(swipeToReplyGesture)
            .overlay(alignment: message.isSentByMe ? .leading : .trailing) { swipeIndicatorOverlay }

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
        switch message.deliveryStatus {
        case .sending:
            Circle()
                .stroke(Color.secondary.opacity(0.5), lineWidth: 1.5)
                .frame(width: 10, height: 10)

        case .sent:
            Circle()
                .fill(Color.secondary.opacity(0.6))
                .frame(width: 10, height: 10)

        case .delivered:
            Circle()
                .fill(Color.green)
                .frame(width: 10, height: 10)

        case .queued:
            Button { onRetry?(message) } label: {
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
            Button { onRetry?(message) } label: {
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
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
    }

    private var swipeToReplyGesture: some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .local)
            .onChanged { value in
                guard !isEditMode else { return }
                let h = value.translation.width
                let v = abs(value.translation.height)
                guard h > 0, h > v else { return }
                swipeOffset = min(h * 0.5, 60)
            }
            .onEnded { _ in
                guard !isEditMode else { return }
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
    }

    @ViewBuilder
    private var swipeIndicatorOverlay: some View {
        if swipeOffset > 10 {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.accentColor)
                .opacity(min(max(Double(swipeOffset / 40), 0), 1))
                .offset(x: message.isSentByMe ? -swipeOffset - 8 : swipeOffset + 8)
                .animation(.interactiveSpring(), value: swipeOffset)
        }
    }
}
