//
//  ChatRowView.swift
//  Construct Messenger
//

import SwiftUI
import Combine

struct ChatRowView: View {
    @ObservedObject var chat: Chat

    var body: some View {
        HStack(spacing: 10) {
            avatarView

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    if let user = chat.otherUser {
                        let alias = user.localAlias?.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let alias, !alias.isEmpty {
                            // Local name override always wins (matches resolvedDisplayName priority).
                            Text(alias)
                                .font(CTFont.bold(13))
                                .foregroundColor(Color.CT.text)
                        } else if !user.displayName.isEmpty {
                            Text(user.displayName)
                                .font(CTFont.bold(13))
                                .foregroundColor(Color.CT.text)
                        } else if !user.username.isEmpty {
                            Text("@\(user.username.lowercased())")
                                .font(CTFont.bold(13))
                                .foregroundColor(Color.CT.text)
                        }
                        else {
                            Text((chat.otherUser?.resolvedDisplayName ?? NSLocalizedString("unknown", comment: "")).uppercased())
                                .font(CTFont.bold(13))
                                .foregroundColor(Color.CT.text)
                        }
                    }
                    Spacer()
                    
                    if let ts = chat.lastMessageTime {
                        Text(ts, formatter: ChatRowView.rowTimeFormatter)
                            .font(CTFont.regular(11))
                            .foregroundColor(Color.CT.textDim)
                    }
                    if chat.isPinned && chat.unreadCount == 0 {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10, weight: .regular))
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
                        Text(chat.unreadCount < 10000 ? "\(chat.unreadCount)" : "9999+")
                            .font(CTFont.bold(13))
                            .foregroundColor(Color.CT.bg)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.CT.accent)
                            .clipShape(Capsule())
                            .animation(.easeInOut(duration: 0.2), value: chat.unreadCount)
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        #if os(iOS)
        .contentShape(.contextMenuPreview, Rectangle())
        #endif
        .contextMenu {
            Button {
                chat.isPinned.toggle()
                try? chat.managedObjectContext?.save()
            } label: {
                Label(LocalizedStringKey(chat.isPinned ? "unpin" : "pin"),
                      systemImage: chat.isPinned ? "pin.slash" : "pin")
            }

            Button {
                chat.unreadCount = chat.unreadCount > 0 ? 0 : 1
                try? chat.managedObjectContext?.save()
            } label: {
                Label(
                    LocalizedStringKey(chat.unreadCount > 0 ? "mark_read" : "mark_unread"),
                    systemImage: chat.unreadCount > 0 ? "envelope.open" : "envelope.badge"
                )
            }

            Divider()

            Button(role: .destructive) {
                NotificationCenter.default.post(name: .deleteChat, object: chat.id)
            } label: {
                Label(LocalizedStringKey("delete"), systemImage: "trash")
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
