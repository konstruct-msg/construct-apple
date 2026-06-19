//
//  MessageInputView.swift
//  Construct Messenger
//
//  Platform wrapper for the chat composer. iOS and macOS keep separate
//  implementations because attachment and voice-input UX diverge.
//

import SwiftUI
import Combine

struct MessageInputView: View {
    @Binding var text: String
    @Binding var droppedImages: [PlatformImage]
    let isSending: Bool
    let replyingTo: Message?
    let quoteOverride: String?
    let editingMessage: Message?
    let onSend: ([MediaAttachment], [URL]) -> Void
    var onSendVoice: ((URL, TimeInterval, [Float]) -> Void)? = nil
    let onCancelReply: () -> Void
    let onCancelEdit: () -> Void

    var body: some View {
        #if os(iOS)
        IOSMessageInputView(
            text: $text,
            droppedImages: $droppedImages,
            isSending: isSending,
            replyingTo: replyingTo,
            quoteOverride: quoteOverride,
            editingMessage: editingMessage,
            onSend: onSend,
            onSendVoice: onSendVoice,
            onCancelReply: onCancelReply,
            onCancelEdit: onCancelEdit
        )
        #elseif os(macOS)
        DesktopMessageInputView(
            text: $text,
            droppedImages: $droppedImages,
            isSending: isSending,
            replyingTo: replyingTo,
            quoteOverride: quoteOverride,
            editingMessage: editingMessage,
            onSend: onSend,
            onSendVoice: onSendVoice,
            onCancelReply: onCancelReply,
            onCancelEdit: onCancelEdit
        )
        #endif
    }
}

#Preview("Input — idle") {
    @Previewable @State var text = ""
    @Previewable @State var dropped: [PlatformImage] = []

    VStack {
        Spacer()
        MessageInputView(
            text: $text,
            droppedImages: $dropped,
            isSending: false,
            replyingTo: nil,
            quoteOverride: nil,
            editingMessage: nil,
            onSend: { _, _ in },
            onCancelReply: {},
            onCancelEdit: {}
        )
    }
    .background(Color.platformBackground)
}

#Preview("Input — with text") {
    @Previewable @State var text = "Hey there! 👋"
    @Previewable @State var dropped: [PlatformImage] = []

    VStack {
        Spacer()
        MessageInputView(
            text: $text,
            droppedImages: $dropped,
            isSending: false,
            replyingTo: nil,
            quoteOverride: nil,
            editingMessage: nil,
            onSend: { _, _ in },
            onCancelReply: {},
            onCancelEdit: {}
        )
    }
    .background(Color.platformBackground)
}
