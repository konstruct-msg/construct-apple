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
    static let minHeight: CGFloat = CTLayout.controlHeight
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

            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey("reply_to_colon"))
                    .font(CTFont.regular(10))
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
        .padding(.vertical, CTLayout.inlinePad)
        .frame(minHeight: ComposerAuxBarLayout.minHeight)
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

            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey("editing_message"))
                    .font(CTFont.regular(10))
                    .foregroundColor(Color.CT.accentDim)
                Text(content)
                    .font(CTFont.regular(13))
                    .lineLimit(1)
                    .foregroundColor(Color.CT.textDim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            cancelButton(action: onCancel)
        }
        .padding(.leading, CTLayout.edgePad)
        .padding(.trailing, CTLayout.inlinePad)
        .padding(.vertical, CTLayout.inlinePad)
        .frame(minHeight: ComposerAuxBarLayout.minHeight)
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
            .font(.system(size: CTLayout.navIconSize, weight: .regular))
            .foregroundColor(Color.CT.textDim)
            .frame(width: CTLayout.hitTarget, height: CTLayout.hitTarget)
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
