//
//  MessageBubbleRegularView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import SwiftUI
import Combine

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
    /// Media open — second argument is the album tile index (0 for single-item).
    let onTapMedia: ((Message, Int) -> Void)?
    let onEdit: ((Message) -> Void)?
    let onReplyWithQuote: ((Message, String) -> Void)?
    /// Tap on the in-bubble reply strip — parent jump + soft focus.
    let onJumpToReply: ((Message) -> Void)?
    let onReact: ((Message, String) -> Void)?

    @GestureState private var swipeOffset: CGFloat = 0
    @State private var isTranscribingVoice = false
    @State private var reactionBadges: [ReactionBadge] = []

    private struct ReactionBadge: Equatable {
        let emoji: String
        let reactorUserId: String
    }

    var body: some View {
        // Parse once per body pass to avoid repeated JSON decode attempts.
        let profileData = MessageBubbleContentParsing.parseProfileMessage(message.displayText)
        let mediaContent = profileData == nil ? MessageBubbleContentParsing.parseMediaMessage(message.displayText) : nil
        let fileContent = (profileData == nil && mediaContent == nil) ? MessageBubbleContentParsing.parseFileMessage(message.displayText) : nil
        let voiceContent = (profileData == nil && mediaContent == nil && fileContent == nil) ? MessageBubbleContentParsing.parseVoiceMessage(message.displayText) : nil

        HStack(spacing: ChatUIConstants.Bubble.rowSpacing) {
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
                Spacer(minLength: ChatUIConstants.Bubble.sideGutter)
            }

            VStack(alignment: message.isSentByMe ? .trailing : .leading, spacing: ChatUIConstants.Bubble.stackSpacing) {
                Group {
                if let profileData {
                    ProfileShareBubbleView(profileData: profileData)
                        .overlay(
                            CTShape.control()
                                .stroke(
                                    isSelected ? Color.CT.accent : Color.clear,
                                    lineWidth: ChatUIConstants.Bubble.selectionStrokeWidth
                                )
                        )
                } else if let mediaContent {
                    VStack(alignment: .leading, spacing: 0) {
                        replyIndicatorView
                        MediaMessageView(
                            mediaContent: mediaContent,
                            message: message,
                            isSelected: isSelected,
                            onTapFullScreen: { itemIndex in onTapMedia?(message, itemIndex) }
                        )
                    }
                } else if let fileContent {
                    VStack(alignment: .leading, spacing: 0) {
                        replyIndicatorView
                        FileAttachmentBubbleView(fileContent: fileContent, isSentByMe: message.isSentByMe)
                            .overlay(
                                CTShape.control()
                                    .stroke(
                                        isSelected ? Color.CT.accent : Color.clear,
                                        lineWidth: ChatUIConstants.Bubble.selectionStrokeWidth
                                    )
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
                    .frame(maxWidth: ChatUIConstants.Bubble.maxWidth)
                    .overlay(
                        CTShape.control()
                            .stroke(
                                isSelected ? Color.CT.accent : Color.clear,
                                lineWidth: ChatUIConstants.Bubble.selectionStrokeWidth
                            )
                    )
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        replyIndicatorView

                        VStack(alignment: .leading, spacing: ChatUIConstants.Bubble.stackSpacing) {
                            let text = message.displayText
                            if text.isEmpty {
                                Text((NSLocalizedString("message_unavailable", comment: "")))
                                    .font(CTFont.regular(ChatUIConstants.Typography.messageTextSize))
                                    .foregroundColor(Color.CT.textDim)
                                    .italic()
                            } else {
                                LinkDetectingText(
                                    text,
                                    color: message.isSentByMe ? Color.CT.outMsgText : Color.CT.text
                                )
                                .font(CTFont.regular(ChatUIConstants.Typography.messageTextSize))
                                .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.horizontal, ChatUIConstants.Bubble.horizontalPadding)
                        .padding(
                            .top,
                            message.replyToContent != nil
                                ? ChatUIConstants.Bubble.tightVerticalPadding
                                : ChatUIConstants.Bubble.verticalPadding
                        )
                        .padding(.bottom, ChatUIConstants.Bubble.verticalPadding)
                    }
                    .background(
                        CTMessageBubbleTheme.regularBackground(
                            isSentByMe: message.isSentByMe,
                            isSelected: isSelected
                        )
                    )
                    .clipShape(CTShape.control())
                    .overlay(
                        Group {
                            if !message.isSentByMe {
                                CTShape.control().stroke(
                                    Color.CT.noise,
                                    lineWidth: ChatUIConstants.Bubble.strokeWidth
                                )
                            }
                        }
                    )
                    // Scoped to the bubble, NOT the whole row. An identifier on a container
                    // propagates down and overwrites its descendants', so putting it on the
                    // row stamped the delivery status too — `chat.message.<id>` where the
                    // status token should have been, and no way to assert "delivered".
                    .accessibilityIdentifier(A11y.Chat.message(message.id))
                }
                }
                .overlay(alignment: message.isSentByMe ? .bottomTrailing : .bottomLeading) {
                    reactionBadgeRow
                }

                if isLastInGroup {
                    HStack(spacing: ChatUIConstants.Bubble.stackSpacing) {
                        if message.isSentByMe {
                            // The label is what makes this an accessibility element at all:
                            // the status is a bare SF Symbol, and SwiftUI drops unlabeled
                            // decorative images from the tree — identifier and all. Without
                            // it the delivery state is invisible to VoiceOver *and* to the
                            // two-simulator stand.
                            deliveryStatusView
                                .accessibilityLabel(Text(message.deliveryStatus.a11yLabel))
                                .accessibilityIdentifier(
                                    A11y.Chat.messageStatus(message.id, message.deliveryStatus)
                                )
                        }

                        if message.isEdited {
                            Text(NSLocalizedString("edited", comment: ""))
                                .font(CTFont.regular(ChatUIConstants.Typography.metaSize))
                                .foregroundColor(Color.CT.textDim)
                        }

                        Text(message.safeTimestamp, style: .time)
                            .font(CTFont.regular(ChatUIConstants.Typography.metaSize))
                            .foregroundColor(Color.CT.textDim)
                    }
                    .padding(.horizontal, ChatUIConstants.Bubble.metaHorizontalPadding)
                }
            }
            // Guard non-finite / tiny container widths from mid-layout geometry passes
            // (they produce "Invalid frame dimension" in the layout engine).
            .frame(
                maxWidth: max(
                    ChatUIConstants.Bubble.minColumnWidth,
                    (containerWidth.isFinite
                        ? containerWidth
                        : ChatUIConstants.Bubble.defaultContainerWidth)
                        * ChatUIConstants.Bubble.maxWidthFraction
                ),
                alignment: message.isSentByMe ? .trailing : .leading
            )
            .contentShape(.interaction, Rectangle())
            #if os(iOS)
            .contentShape(.contextMenuPreview, Rectangle())
            #endif
            .onTapGesture {
                if isEditMode {
                    onSelect?(message)
                }
            }
            // Simultaneous so swipe-to-reply and long-press keep the arena.
            // High-priority would steal the drag the way the old rightward reply did.
            .simultaneousGesture(doubleTapLikeGesture)
            .onAppear { reloadReactionBadges() }
            .onReceive(NotificationCenter.default.publisher(for: ReactionStore.didChange)) { note in
                guard let target = note.object as? String,
                      target.caseInsensitiveCompare(message.id) == .orderedSame
                else { return }
                reloadReactionBadges()
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

                    // Editable: plain text (edit the text) and media/photo/video (edit the
                    // caption — the edit pipeline rebuilds the album, see ChatSendCoordinator).
                    // NOT editable: voice, files, profile shares — their payload has no text the
                    // user should edit, and a text edit would destroy/garble it.
                    if message.isSentByMe,
                       message.hasDecryptedContent,
                       fileContent == nil,
                       voiceContent == nil,
                       profileData == nil,
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
            .offset(x: -swipeOffset)
            // Tracks the finger closely while dragging and springs home on release —
            // `@GestureState` resets instantly, so the animation has to live here.
            .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.8), value: swipeOffset)
            .gesture(swipeToReplyGesture)
            // The bubble slides left, so the space it vacates is on its trailing side — the same
            // side for sent and received alike, which is why this no longer switches on the author.
            .overlay(alignment: .trailing) { swipeIndicatorOverlay }

            if !message.isSentByMe {
                Spacer(minLength: ChatUIConstants.Bubble.sideGutter)
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
                .font(CTFont.regular(ChatUIConstants.Typography.metaSize))
                .foregroundColor(Color.CT.textDim)

        case .sent:
            Image(systemName: "circle.fill")
                .font(CTFont.regular(ChatUIConstants.Typography.metaSize))
                .foregroundColor(Color.CT.textDim)

        case .delivered:
            Image(systemName: "checkmark.circle")
                .font(CTFont.regular(ChatUIConstants.Typography.metaSize))
                .foregroundColor(.green)

        case .queued:
            Button { onRetry?(message) } label: {
                Image(systemName: "arrow.clockwise")
                    .font(CTFont.regular(ChatUIConstants.Typography.metaSize))
                    .foregroundColor(Color.CT.textDim)
            }
            .buttonStyle(.plain)

        case .failed:
            Button { onRetry?(message) } label: {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(CTFont.regular(ChatUIConstants.Typography.metaSize))
                    .foregroundColor(Color.CT.danger)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var replyIndicatorView: some View {
        let hasReply = message.replyToMessageId != nil && !(message.replyToMessageId ?? "").isEmpty
        if hasReply {
            Button {
                onJumpToReply?(message)
            } label: {
                HStack(spacing: ChatUIConstants.Bubble.stackSpacing) {
                    Rectangle()
                        .fill(Color.CT.accentDim)
                        .frame(width: ChatUIConstants.Bubble.replyAccentWidth)

                    if let replyContent = message.replyToContent {
                        ReplyPreviewContent(
                            content: replyContent,
                            messageId: message.replyToMessageId,
                            thumbnailSize: ChatUIConstants.Bubble.replyThumbnailSize,
                            lineLimit: 2
                        )
                        .padding(.vertical, ChatUIConstants.Bubble.tightVerticalPadding)
                        .padding(.trailing, ChatUIConstants.Bubble.tightVerticalPadding)
                    } else {
                        Text("Original message")
                            .font(CTFont.regular(ChatUIConstants.Typography.systemSize))
                            .foregroundColor(Color.CT.textDim)
                            .padding(.vertical, ChatUIConstants.Bubble.tightVerticalPadding)
                            .padding(.trailing, ChatUIConstants.Bubble.tightVerticalPadding)
                    }
                }
                .padding(.horizontal, ChatUIConstants.Bubble.horizontalPadding)
                .padding(.top, ChatUIConstants.Bubble.verticalPadding)
                .padding(.bottom, ChatUIConstants.Bubble.tightVerticalPadding)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("jump_to_replied_message", comment: "Jump to the message this reply quotes"))
        }
    }

    private var doubleTapLikeGesture: some Gesture {
        TapGesture(count: 2).onEnded {
            likeIfPossible()
        }
    }

    private func likeIfPossible() {
        guard !isEditMode, let onReact else { return }
        onReact(message, ReactionReducer.likeEmoji)
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    private func reloadReactionBadges() {
        guard let context = message.managedObjectContext else {
            reactionBadges = []
            return
        }
        reactionBadges = ReactionStore.reactions(on: message.id, in: context).map {
            ReactionBadge(emoji: $0.emoji, reactorUserId: $0.reactorUserId)
        }
    }

    @ViewBuilder
    private var reactionBadgeRow: some View {
        if !reactionBadges.isEmpty {
            HStack(spacing: 2) {
                ForEach(reactionBadges, id: \.reactorUserId) { badge in
                    Button {
                        guard !isEditMode else { return }
                        onReact?(message, badge.emoji)
                    } label: {
                        Text(badge.emoji)
                            .font(CTFont.regular(ChatUIConstants.Reaction.badgeFontSize))
                            .padding(.horizontal, ChatUIConstants.Reaction.badgePadH)
                            .padding(.vertical, ChatUIConstants.Reaction.badgePadV)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        Text(String(format: NSLocalizedString("reaction_a11y", comment: ""), badge.emoji))
                    )
                }
            }
            .background(Color.CT.bgMsg)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.CT.noise, lineWidth: ChatUIConstants.Bubble.strokeWidth))
            .offset(y: ChatUIConstants.Reaction.badgeOverlap)
        }
    }

    /// How far the bubble should trail the finger, or nil when this drag is not a reply
    /// swipe at all.
    ///
    /// **Reply swipes go left.** They used to go right, the same way as the interactive pop,
    /// and the two were told apart by where the drag started: anything inside a 44pt leading
    /// strip was conceded to the pop. That is a truce, not a separation — one gesture in two
    /// roles, resolved by a margin. A back swipe beginning further inboard still quoted a
    /// message, and the concession cost the leftmost 44pt of every incoming bubble, exactly
    /// where the short ones live.
    ///
    /// Direction separates them completely and needs no strip: the pop travels right, a reply
    /// travels left, and no start position can make one look like the other. (RTL locales would
    /// mirror the pop and re-open the conflict — the app ships en/ru/ja, and this is the line
    /// to revisit if that changes.)
    ///
    /// Reads only `translation`, so the answer is derived fresh from the gesture rather than
    /// latched in state — no armed/rejected flag is left behind when the scroll view takes the
    /// drag away. Not private: the rules are the whole fix, and `DragGesture.Value` cannot be
    /// built in a test, so the decision is taken on plain numbers a test can supply.
    ///
    /// - Returns: travel as a positive magnitude, in the direction of the swipe. The call site
    ///   applies the sign — the bubble moves by `-offset`.
    static func replySwipeOffset(translation: CGSize) -> CGFloat? {
        let h = -translation.width          // leftward travel, as a positive number
        let v = abs(translation.height)
        guard h > 0, h > v * ChatUIConstants.ReplySwipe.directionRatio else { return nil }
        return min(h * 0.5, ChatUIConstants.ReplySwipe.maxOffset)
    }

    private static func replySwipeOffset(for value: DragGesture.Value) -> CGFloat? {
        replySwipeOffset(translation: value.translation)
    }

    private var swipeToReplyGesture: some Gesture {
        DragGesture(
            minimumDistance: ChatUIConstants.ReplySwipe.minimumDistance,
            coordinateSpace: .global
        )
        // `@GestureState` snaps back on its own when the gesture ends *or is cancelled*,
        // so a drag stolen mid-way can no longer leave the bubble parked off-centre.
        .updating($swipeOffset) { value, offset, _ in
            guard !isEditMode else { return }
            offset = Self.replySwipeOffset(for: value) ?? 0
        }
        .onEnded { value in
            guard !isEditMode,
                  let offset = Self.replySwipeOffset(for: value),
                  offset >= ChatUIConstants.ReplySwipe.commitOffset
            else { return }
            onReply?(message)
            #if canImport(UIKit)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            #endif
        }
    }

    @ViewBuilder
    private var swipeIndicatorOverlay: some View {
        if swipeOffset > ChatUIConstants.ReplySwipe.indicatorThreshold {
            Image(systemName: "arrow.uturn.left")
                .font(CTFont.regular(14))
                .foregroundColor(Color.CT.accent)
                .opacity(min(max(Double(swipeOffset / ChatUIConstants.ReplySwipe.commitOffset), 0), 1))
                // The overlay is attached after `.offset(x: -swipeOffset)` and therefore moves
                // with the bubble; `+swipeOffset` holds it still so the bubble slides out from
                // under it, and the 8pt is the gap it settles into.
                .offset(x: swipeOffset + 8)
        }
    }
}
