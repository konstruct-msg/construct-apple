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
    @State private var isTranscribingVoice = false

    var body: some View {
        // Parse once per body pass to avoid repeated JSON decode attempts.
        let profileData = MessageBubbleContentParsing.parseProfileMessage(message.displayText)
        let mediaContent = profileData == nil ? MessageBubbleContentParsing.parseMediaMessage(message.displayText) : nil
        let fileContent = (profileData == nil && mediaContent == nil) ? MessageBubbleContentParsing.parseFileMessage(message.displayText) : nil
        let voiceContent = (profileData == nil && mediaContent == nil && fileContent == nil) ? MessageBubbleContentParsing.parseVoiceMessage(message.displayText) : nil

        HStack(spacing: 8) {
            // Selection checkbox in edit mode - positioned based on message direction
            if isEditMode && !message.isSentByMe {
                Button {
                    onSelect?(message)
                } label: {
                    if isSelected {
                        Image(systemName: "circle")
                            .font(CTFont.regular(14))
                            .foregroundColor(Color.CT.textDim)
                    }
                    else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(CTFont.regular(14))
                            .foregroundColor(Color.CT.accentDim)
                    }
                }
                .buttonStyle(.plain)
            }

            if message.isSentByMe {
                Spacer(minLength: 60)
            }

            VStack(alignment: message.isSentByMe ? .trailing : .leading, spacing: 4) {
                if let profileData {
                    ProfileShareBubbleView(profileData: profileData)
                        .overlay(
                            Rectangle()
                                .stroke(isSelected ? Color.CT.accent : Color.clear, lineWidth: 2)
                        )
                } else if let mediaContent {
                    VStack(alignment: .leading, spacing: 0) {
                        replyIndicatorView
                        MediaMessageView(
                            mediaContent: mediaContent,
                            message: message,
                            isSelected: isSelected,
                            onTapFullScreen: { onTapMedia?(message) }
                        )
                    }
                } else if let fileContent {
                    VStack(alignment: .leading, spacing: 0) {
                        replyIndicatorView
                        FileAttachmentBubbleView(fileContent: fileContent, isSentByMe: message.isSentByMe)
                            .overlay(
                                Rectangle()
                                    .stroke(isSelected ? Color.CT.accent : Color.clear, lineWidth: 2)
                            )
                    }
                } else if let voiceContent {
                    VoiceMessageBubbleView(
                        voiceContent: voiceContent,
                        isSentByMe: message.isSentByMe,
                        deliveryStatus: message.deliveryStatus,
                        onRetry: onRetry != nil ? { onRetry?(message) } : nil,
                        transcript: message.transcriptText,
                        isTranscribing: isTranscribingVoice,
                        onTranscribe: {
                            guard !isTranscribingVoice else { return }
                            isTranscribingVoice = true
                            Task {
                                defer { isTranscribingVoice = false }
                                do {
                                    let data = try await MediaManager.shared.downloadAndDecryptMedia(
                                        mediaId: voiceContent.mediaId,
                                        mediaUrl: voiceContent.mediaUrl,
                                        mediaKey: voiceContent.mediaKey
                                    )
                                    if let ctx = message.managedObjectContext {
                                        try await VoiceTranscriptionService.shared.transcribe(
                                            audioData: data,
                                            message: message,
                                            context: ctx
                                        )
                                    }
                                } catch {
                                    Log.error("Transcription failed: \(error)", category: "MessageBubbleRegularView")
                                }
                            }
                        }
                    )
                    .frame(maxWidth: 360)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(isSelected ? Color.CT.accent : Color.clear, lineWidth: 2)
                    )
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        replyIndicatorView

                        VStack(alignment: .leading, spacing: 4) {
                            let text = message.displayText
                            if text.isEmpty {
                                Text("[!] \(NSLocalizedString("message_unavailable", comment: ""))")
                                    .font(CTFont.regular(ChatUIConstants.Typography.messageTextSize))
                                    .foregroundColor(Color.CT.textDim)
                                    .italic()
                            } else {
                                LinkDetectingText(
                                    text,
                                    color: message.isSentByMe ? Color.CT.outMsgText : Color.CT.text
                                )
                                .font(CTFont.regular(ChatUIConstants.Typography.messageTextSize))
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, message.replyToContent != nil ? 4 : 8)
                        .padding(.bottom, 8)
                    }
                    .background(
                        CTMessageBubbleTheme.regularBackground(
                            isSentByMe: message.isSentByMe,
                            isSelected: isSelected
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        Group {
                            if !message.isSentByMe {
                                RoundedRectangle(cornerRadius: 10).stroke(Color.CT.noise, lineWidth: 0.5)
                            }
                        }
                    )
                }

                if isLastInGroup {
                    HStack(spacing: 4) {
                        if message.isSentByMe {
                            deliveryStatusView
                        }

                        if message.isEdited {
                            Text(NSLocalizedString("edited", comment: ""))
                                .font(CTFont.regular(10))
                                .foregroundColor(Color.CT.textDim)
                        }

                        Text(message.safeTimestamp, style: .time)
                            .font(CTFont.regular(10))
                            .foregroundColor(Color.CT.textDim)
                    }
                    .padding(.horizontal, 4)
                }
            }
            .frame(maxWidth: containerWidth * 0.7, alignment: message.isSentByMe ? .trailing : .leading)
            .contentShape(.interaction, Rectangle())
            #if os(iOS)
            .contentShape(.contextMenuPreview, Rectangle())
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
                       !message.displayText.isEmpty,
                       mediaContent == nil,
                       fileContent == nil
                    {
                        Button { onReplyWithQuote(message, message.displayText) } label: {
                            Label(NSLocalizedString("quote_reply", comment: ""), systemImage: "text.quote")
                        }
                    }

                    if message.isSentByMe,
                       message.hasDecryptedContent,
                       !message.displayText.hasPrefix("[MEDIA]"),
                       !message.displayText.hasPrefix("[FILE]"),
                       let onEdit
                    {
                        Button { onEdit(message) } label: {
                            Label(NSLocalizedString("edit_message", comment: ""), systemImage: "pencil")
                        }
                    }

                    Button { PlatformClipboard.copy(message.displayText) } label: {
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

            if isEditMode && message.isSentByMe {
                Button {
                    onSelect?(message)
                } label: {
                    if isSelected {
                        Image(systemName: "circle")
                            .font(CTFont.regular(14))
                            .foregroundColor(Color.CT.textDim)
                    }
                    else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(CTFont.regular(14))
                            .foregroundColor(Color.CT.accentDim)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var deliveryStatusView: some View {
        switch message.deliveryStatus {
        case .sending:
            Image(systemName: "circle")
                .font(CTFont.regular(10))
                .foregroundColor(Color.CT.textDim)

        case .sent:
            Image(systemName: "circle.fill")
                .font(CTFont.regular(10))
                .foregroundColor(Color.CT.textDim)

        case .delivered:
            Image(systemName: "checkmark.circle")
                .font(CTFont.regular(10))
                .foregroundColor(.green)

        case .queued:
            Button { onRetry?(message) } label: {
                Image(systemName: "arrow.clockwise")
                    .font(CTFont.regular(10))
                    .foregroundColor(Color.CT.textDim)
            }
            .buttonStyle(.plain)

        case .failed:
            Button { onRetry?(message) } label: {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(CTFont.regular(10))
                    .foregroundColor(Color.CT.danger)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var replyIndicatorView: some View {
        let hasReply = message.replyToMessageId != nil && !(message.replyToMessageId ?? "").isEmpty
        if hasReply {
            HStack(spacing: 4) {
                Rectangle()
                    .fill(Color.CT.accentDim)
                    .frame(width: 2)

                if let replyContent = message.replyToContent {
                    ReplyPreviewContent(
                        content: replyContent,
                        messageId: message.replyToMessageId,
                        thumbnailSize: 40,
                        lineLimit: 2
                    )
                    .padding(.vertical, 4)
                    .padding(.trailing, 4)
                } else {
                    Text("Original message")
                        .font(CTFont.regular(11))
                        .foregroundColor(Color.CT.textDim)
                        .padding(.vertical, 4)
                        .padding(.trailing, 4)
                }
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
            Image(systemName: "arrow.uturn.right")
                .font(CTFont.regular(14))
                .foregroundColor(Color.CT.accent)
                .opacity(min(max(Double(swipeOffset / 40), 0), 1))
                .offset(x: message.isSentByMe ? -swipeOffset - 8 : swipeOffset + 8)
                .animation(.interactiveSpring(), value: swipeOffset)
        }
    }
}
