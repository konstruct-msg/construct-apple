//
//  MessageInfoSheet.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 31.12.2025.
//

import SwiftUI

struct MessageInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    let message: Message

    var body: some View {
        NavigationStack {
            List {
                // Message Content
                Section {
                    if let content = message.decryptedContent {
                        Text(content)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("message")
                }

                // Delivery Information
                Section {
                    InfoRow(
                        label: "status",
                        value: message.deliveryStatus.displayName,
                        icon: message.deliveryStatus.icon,
                        iconColor: statusColor
                    )

                    InfoRow(
                        label: "sent",
                        value: formatDate(message.timestamp)
                    )

                    if message.isSentByMe {
                        InfoRow(
                            label: "direction",
                            value: NSLocalizedString("outgoing", comment: ""),
                            icon: "arrow.up.circle.fill",
                            iconColor: .blue
                        )
                    } else {
                        InfoRow(
                            label: "direction",
                            value: NSLocalizedString("incoming", comment: ""),
                            icon: "arrow.down.circle.fill",
                            iconColor: .green
                        )
                    }

                    if message.retryCount > 0 {
                        InfoRow(
                            label: "retry_count",
                            value: "\(message.retryCount)",
                            icon: "arrow.clockwise",
                            iconColor: .orange
                        )
                    }
                } header: {
                    Text("delivery_information")
                }

                // Technical Details
                Section {
                    InfoRow(
                        label: "message_id",
                        value: message.id
                    )

                    InfoRow(
                        label: "from",
                        value: message.fromUserId
                    )

                    InfoRow(
                        label: "to",
                        value: message.toUserId
                    )

                    if let replyToId = message.replyToMessageId {
                        InfoRow(
                            label: "reply_to",
                            value: replyToId,
                            icon: "arrowshape.turn.up.left"
                        )
                    }
                } header: {
                    Text("technical_details")
                }

                // Encryption
                Section {
                    InfoRow(
                        label: "encryption",
                        value: NSLocalizedString("end_to_end", comment: ""),
                        icon: "lock.fill",
                        iconColor: .green
                    )

                    InfoRow(
                        label: "protocol",
                        value: NSLocalizedString("double_ratchet", comment: "")
                    )
                } header: {
                    Text("security")
                }
            }
            .navigationTitle("message_info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var statusColor: Color {
        switch message.deliveryStatus {
        case .sending:
            return .blue
        case .sent:
            return .gray
        case .delivered:
            return .green
        case .queued:
            return .orange
        case .failed:
            return .red
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}

struct InfoRow: View {
    let label: LocalizedStringKey
    let value: String
    var icon: String? = nil
    var iconColor: Color = .secondary

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 120, alignment: .leading)

            Spacer()

            HStack(spacing: 6) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundColor(iconColor)
                }

                Text(value)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}

#Preview {
    let container = PreviewHelpers.createPreviewContainer()
    let context = container.viewContext

    let user = PreviewHelpers.createSampleUser(context: context, username: "alice", displayName: "Alice")
    let chat = PreviewHelpers.createSampleChat(context: context, with: user)
    let message = PreviewHelpers.createSampleMessage(
        context: context,
        chat: chat,
        isSentByMe: true,
        text: "Hello, this is a test message!"
    )

    return MessageInfoSheet(message: message)
}
