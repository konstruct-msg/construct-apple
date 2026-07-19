//
//  MessageReplyEditBar.swift
//  Construct Messenger
//
//  Reply preview bar and edit-mode banner shown above the message input field.
//

import SwiftUI
import Combine

// MARK: - Shared chrome

private enum ComposerAuxBarLayout {
    static let accentBarWidth: CGFloat = 2
    /// Compact cancel glyph (full hit target still applied via contentShape padding).
    static let cancelIconSize: CGFloat = 18
    static let cancelHit: CGFloat = 32
    static let verticalPadding: CGFloat = 6
    static let labelPreviewSpacing: CGFloat = 1
}

// MARK: - Reply Bar

struct MessageReplyBar: View {
    let content: String?
    let messageId: String?
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: CTLayout.chromeGap) {
            // Height follows text/thumbnail only — never `.infinity` (that blew the bar
            // to full viewport when the composer safeAreaInset proposed a tall height).
            Rectangle()
                .fill(Color.CT.accent)
                .frame(width: ComposerAuxBarLayout.accentBarWidth)

            VStack(alignment: .leading, spacing: ComposerAuxBarLayout.labelPreviewSpacing) {
                Text(LocalizedStringKey("reply_to_colon"))
                    .font(CTFont.regular(ChatUIConstants.Typography.metaSize))
                    .foregroundColor(Color.CT.textDim)
                ReplyPreviewContent(
                    content: content,
                    messageId: messageId,
                    thumbnailSize: ChatUIConstants.Bubble.replyBarThumbnailSize,
                    lineLimit: 1
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            cancelButton(action: onCancel)
        }
        .padding(.leading, CTLayout.edgePad)
        .padding(.trailing, CTLayout.inlinePad)
        .padding(.vertical, ComposerAuxBarLayout.verticalPadding)
        // No minHeight = controlHeight — that forced a tall empty strip above the field.
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.CT.bgMsg)
        .clipShape(CTShape.card())
        .overlay(CTShape.card().stroke(Color.CT.noise, lineWidth: ChatUIConstants.Bubble.strokeWidth))
        .padding(.horizontal, ChatUIConstants.Shell.auxOuterPad)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - Edit Bar

struct MessageEditBar: View {
    let content: String
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: CTLayout.chromeGap) {
            Rectangle()
                .fill(Color.CT.accentDim)
                .frame(width: ComposerAuxBarLayout.accentBarWidth)

            VStack(alignment: .leading, spacing: ComposerAuxBarLayout.labelPreviewSpacing) {
                Text(LocalizedStringKey("editing_message"))
                    .font(CTFont.regular(ChatUIConstants.Typography.metaSize))
                    .foregroundColor(Color.CT.accentDim)
                Text(content)
                    .font(CTFont.regular(12))
                    .lineLimit(1)
                    .foregroundColor(Color.CT.textDim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            cancelButton(action: onCancel)
        }
        .padding(.leading, CTLayout.edgePad)
        .padding(.trailing, CTLayout.inlinePad)
        .padding(.vertical, ComposerAuxBarLayout.verticalPadding)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.CT.bgMsg)
        .clipShape(CTShape.card())
        .overlay(CTShape.card().stroke(Color.CT.noise, lineWidth: ChatUIConstants.Bubble.strokeWidth))
        .padding(.horizontal, ChatUIConstants.Shell.auxOuterPad)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - Cancel control

private func cancelButton(action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: "xmark.circle.fill")
            .font(.system(size: ComposerAuxBarLayout.cancelIconSize, weight: .regular))
            .foregroundColor(Color.CT.textDim)
            .frame(
                width: ComposerAuxBarLayout.cancelHit,
                height: ComposerAuxBarLayout.cancelHit
            )
            .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(NSLocalizedString("close", comment: ""))
}

// MARK: - Previews

#Preview("Reply Bar") {
    MessageReplyBar(
        content: "Hey, how are you doing today?",
        messageId: nil,
        onCancel: {}
    )
    .padding()
    .ctBackground()
}

#Preview("Edit Bar") {
    MessageEditBar(
        content: "This is the message being edited",
        onCancel: {}
    )
    .padding()
    .ctBackground()
}
