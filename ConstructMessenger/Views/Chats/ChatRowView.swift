//
//  ChatRowView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import SwiftUI

struct ChatRowView: View {
    @ObservedObject var chat: Chat

    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            Group {
                if let avatarData = chat.otherUser?.avatarData,
                   let avatarImage = ImageHelper.imageFromData(avatarData) {
                    Image(platformImage: avatarImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: AvatarStyle.chatSize, height: AvatarStyle.chatSize)
                        .clipShape(AvatarStyle.squircle(AvatarStyle.chatSize))
                } else {
                    AvatarStyle.squircle(AvatarStyle.chatSize)
                        .fill(Color.hexagonAccent(for: chat.otherUser?.id ?? ""))
                        .frame(width: AvatarStyle.chatSize, height: AvatarStyle.chatSize)
                        .overlay {
                            Text(initials)
                                .foregroundColor(.white)
                                .fontWeight(.semibold)
                        }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(chat.otherUser?.resolvedDisplayName ?? NSLocalizedString("unknown", comment: "Unknown user"))
                    .fontWeight(.semibold)

                if let lastMessage = chat.lastMessageText {
                    Text(Chat.formatPreviewText(lastMessage))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                if chat.isPinned && chat.unreadCount == 0 {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if chat.unreadCount > 0 {
                    Text(chat.unreadCount < 100 ? "\(chat.unreadCount)" : "99+")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                        .animation(.easeInOut(duration: 0.2), value: chat.unreadCount)
                }
            }

        }
        .padding(.vertical, 4)
        // Right-click context menu on macOS
        .contextMenu {
            Button {
                chat.isPinned.toggle()
                try? chat.managedObjectContext?.save()
            } label: {
                Label(chat.isPinned ? "Unpin" : "Pin", systemImage: chat.isPinned ? "pin.slash" : "pin")
            }

            if chat.unreadCount > 0 {
                Button {
                    chat.unreadCount = 0
                    try? chat.managedObjectContext?.save()
                } label: {
                    Label("Mark as Read", systemImage: "envelope.open")
                }
            }

            Divider()

            Button(role: .destructive) {
                // Chat deletion is handled via ChatManagementService; tag it for parent list to process
                NotificationCenter.default.post(name: .deleteChat, object: chat.id)
            } label: {
                Label("Delete Chat", systemImage: "trash")
            }
        }

    private var initials: String {
        guard let displayName = chat.otherUser?.resolvedDisplayName else { return "?" }
        let components = displayName.split(separator: " ")
        if components.count >= 2 {
            return String(components[0].prefix(1) + components[1].prefix(1)).uppercased()
        }
        return String(displayName.prefix(2)).uppercased()
    }
}
