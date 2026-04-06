//
//  ChatRowView.swift
//  Construct Messenger
//

import SwiftUI

struct ChatRowView: View {
    @ObservedObject var chat: Chat

    var body: some View {
        HStack(spacing: 10) {
            avatarView

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    // <@username> only when user has a real handle; otherwise deterministic name
                    if let user = chat.otherUser, !user.username.isEmpty {
                        Text("<@\(user.username.lowercased())>")
                            .font(CTFont.bold(13))
                            .foregroundColor(Color.CT.text)
                    } else {
                        Text((chat.otherUser?.resolvedDisplayName ?? NSLocalizedString("unknown", comment: "")).uppercased())
                            .font(CTFont.bold(13))
                            .foregroundColor(Color.CT.text)
                    }
                    Spacer()
                    if let ts = chat.lastMessageTime {
                        Text(ts, formatter: ChatRowView.rowTimeFormatter)
                            .font(CTFont.regular(11))
                            .foregroundColor(Color.CT.textDim)
                    }
                    if chat.isPinned && chat.unreadCount == 0 {
                        Text(CTSymbol.pin)
                            .font(CTFont.regular(10))
                            .foregroundColor(Color.CT.textDim)
                    }
                }

                HStack {
                    if let lastMessage = chat.lastMessageText {
                        Text(Chat.formatPreviewText(lastMessage))
                            .font(CTFont.regular(12))
                            .foregroundColor(Color.CT.textDim)
                            .lineLimit(1)
                    }
                    Spacer()
                    if chat.unreadCount > 0 {
                        Text(chat.unreadCount < 100 ? "[\(chat.unreadCount)]" : "[99+]")
                            .font(CTFont.bold(11))
                            .foregroundColor(Color.CT.bg)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.CT.accent)
                            .clipShape(Rectangle())
                            .animation(.easeInOut(duration: 0.2), value: chat.unreadCount)
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .contextMenu {
            Button {
                chat.isPinned.toggle()
                try? chat.managedObjectContext?.save()
            } label: {
                Label(chat.isPinned ? "Unpin" : "Pin",
                      systemImage: chat.isPinned ? "pin.slash" : "pin")
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
                NotificationCenter.default.post(name: .deleteChat, object: chat.id)
            } label: {
                Label("Delete Chat", systemImage: "trash")
            }
        }
    }

    // MARK: - Avatar

    @ViewBuilder
    private var avatarView: some View {
        let seed = chat.otherUser?.id ?? initials
        if let data = chat.otherUser?.avatarData,
           let platformImg = ImageHelper.imageFromData(data) {
            CTHexAvatar(initials: initials, image: Image(platformImage: platformImg), size: .medium, colorSeed: seed)
        } else {
            CTHexAvatar(initials: initials, size: .medium, colorSeed: seed)
        }
    }

    // MARK: - Helpers

    private var initials: String {
        guard let name = chat.otherUser?.resolvedDisplayName else { return "?" }
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    static let rowTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}
