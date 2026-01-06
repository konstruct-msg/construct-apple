//
//  MessageBubble.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import SwiftUI

struct MessageBubble: View {
    let message: Message
    let isLastInGroup: Bool
    let onRetry: ((Message) -> Void)?
    let onReply: ((Message) -> Void)?
    let onDelete: ((Message) -> Void)?

    @State private var showMessageInfo = false

    init(
        message: Message,
        isLastInGroup: Bool = true,
        onRetry: ((Message) -> Void)? = nil,
        onReply: ((Message) -> Void)? = nil,
        onDelete: ((Message) -> Void)? = nil
    ) {
        self.message = message
        self.isLastInGroup = isLastInGroup
        self.onRetry = onRetry
        self.onReply = onReply
        self.onDelete = onDelete
    }

    var body: some View {
        HStack {
            if message.isSentByMe {
                Spacer(minLength: 60)
            }

            VStack(alignment: message.isSentByMe ? .trailing : .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 0) {
                    // Reply/Quote preview
                    if let replyContent = message.replyToContent {
                        HStack(spacing: 4) {
                            Rectangle()
                                .fill(message.isSentByMe ? Color.white.opacity(0.5) : Color.blue.opacity(0.5))
                                .frame(width: 3)

                            Text(replyContent)
                                .font(.caption)
                                .foregroundColor(message.isSentByMe ? .white.opacity(0.8) : .secondary)
                                .lineLimit(2)
                                .padding(.vertical, 4)
                                .padding(.trailing, 8)
                        }
                        .padding(.leading, 8)
                        .padding(.top, 8)
                    }

                    // Main message content
                    Text(message.decryptedContent ?? NSLocalizedString("encrypted", comment: "Fallback for encrypted content"))
                        .padding(.horizontal, 12)
                        .padding(.vertical, message.replyToContent != nil ? 4 : 8)
                        .padding(.bottom, message.replyToContent != nil ? 8 : 0)
                }
                .background(message.isSentByMe ? Color.blue : Color.gray.opacity(0.2))
                .foregroundColor(message.isSentByMe ? .white : .primary)
                .cornerRadius(16)

                if isLastInGroup {
                    HStack(spacing: 4) {
                        if message.isSentByMe {
                            deliveryStatusView
                        }

                        Text(message.timestamp, style: .time)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 4)
                }
            }
            .frame(maxWidth: UIScreen.main.bounds.width * 0.7, alignment: message.isSentByMe ? .trailing : .leading)

            if !message.isSentByMe {
                Spacer(minLength: 60)
            }
        }
        .contextMenu {
            // Reply - только для чужих сообщений или если есть callback
            if let onReply = onReply {
                Button {
                    onReply(message)
                } label: {
                    Label("reply", systemImage: "arrowshape.turn.up.left")
                }
            }

            // Copy text
            Button {
                UIPasteboard.general.string = message.decryptedContent
            } label: {
                Label("copy", systemImage: "doc.on.doc")
            }

            // Message info
            Button {
                showMessageInfo = true
            } label: {
                Label("info", systemImage: "info.circle")
            }

            Divider()

            // Delete - только для своих сообщений
            if message.isSentByMe, let onDelete = onDelete {
                Button(role: .destructive) {
                    onDelete(message)
                } label: {
                    Label("delete", systemImage: "trash")
                }
            }

            // Retry - только для failed/queued сообщений
            if (message.deliveryStatus == .failed || message.deliveryStatus == .queued),
               let onRetry = onRetry {
                Button {
                    onRetry(message)
                } label: {
                    Label("retry", systemImage: "arrow.clockwise")
                }
            }
        }
        .sheet(isPresented: $showMessageInfo) {
            MessageInfoSheet(message: message)
        }
    }

    @ViewBuilder
    private var deliveryStatusView: some View {
        let status = message.deliveryStatus

        switch status {
        case .sending:
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 12, height: 12)

        case .sent:
            Image(systemName: "checkmark")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

        case .delivered:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundColor(.green)

        case .queued:
            Button {
                if let onRetry = onRetry {
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
                if let onRetry = onRetry {
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
}
