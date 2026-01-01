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
                    Text("Message")
                }

                // Delivery Information
                Section {
                    InfoRow(
                        label: "Status",
                        value: message.deliveryStatus.displayName,
                        icon: message.deliveryStatus.icon,
                        iconColor: statusColor
                    )

                    InfoRow(
                        label: "Sent",
                        value: formatDate(message.timestamp)
                    )

                    if message.isSentByMe {
                        InfoRow(
                            label: "Direction",
                            value: "Outgoing",
                            icon: "arrow.up.circle.fill",
                            iconColor: .blue
                        )
                    } else {
                        InfoRow(
                            label: "Direction",
                            value: "Incoming",
                            icon: "arrow.down.circle.fill",
                            iconColor: .green
                        )
                    }

                    if message.retryCount > 0 {
                        InfoRow(
                            label: "Retry Count",
                            value: "\(message.retryCount)",
                            icon: "arrow.clockwise",
                            iconColor: .orange
                        )
                    }
                } header: {
                    Text("Delivery Information")
                }

                // Technical Details
                Section {
                    InfoRow(
                        label: "Message ID",
                        value: message.id ?? "Unknown"
                    )

                    InfoRow(
                        label: "From",
                        value: message.fromUserId
                    )

                    InfoRow(
                        label: "To",
                        value: message.toUserId
                    )

                    if let replyToId = message.replyToMessageId {
                        InfoRow(
                            label: "Reply To",
                            value: replyToId,
                            icon: "arrowshape.turn.up.left"
                        )
                    }
                } header: {
                    Text("Technical Details")
                }

                // Encryption
                Section {
                    InfoRow(
                        label: "Encryption",
                        value: "End-to-End",
                        icon: "lock.fill",
                        iconColor: .green
                    )

                    InfoRow(
                        label: "Protocol",
                        value: "Double Ratchet"
                    )
                } header: {
                    Text("Security")
                }
            }
            .navigationTitle("Message Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
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
    let label: String
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
