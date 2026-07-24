//
//  ChatRowView.swift
//  Construct Messenger
//

import SwiftUI
import Combine

struct ChatRowView: View {
    @ObservedObject var chat: Chat

    var body: some View {
        // Profile shares update `User` (displayName, avatarData), not `Chat`.
        // @ObservedObject on Chat alone does not refresh when a related User changes.
        if let user = chat.otherUser {
            ChatRowBody(chat: chat, user: user)
        } else {
            ChatRowOrphanBody(chat: chat)
        }
    }

    static let rowTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}

// MARK: - Row body

private struct ChatRowBody: View {
    @ObservedObject var chat: Chat
    @ObservedObject var user: User

    var body: some View {
        ChatRowLayout(chat: chat, user: user)
    }
}

/// Rare fallback when `chat.otherUser` is nil — observes Chat only.
private struct ChatRowOrphanBody: View {
    @ObservedObject var chat: Chat

    var body: some View {
        ChatRowLayout(chat: chat, user: nil)
    }
}

// MARK: - Shared layout

private struct ChatRowLayout: View {
    let chat: Chat
    let user: User?

    var body: some View {
        HStack(alignment: .center, spacing: CTLayout.chromeGap) {
            avatarView

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: CTLayout.inlinePad) {
                    if let user {
                        displayNameView(for: user)
                            .lineLimit(1)
                        if user.ktStatus == .keyChanged || user.ktStatus == .failed {
                            Image(systemName: "exclamationmark.shield.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.CT.danger)
                                .accessibilityLabel(Text(LocalizedStringKey("kt_warning")))
                        }
                    }
                    Spacer(minLength: 4)

                    if let ts = chat.lastMessageTime {
                        Text(ts, formatter: ChatRowView.rowTimeFormatter)
                            .font(CTFont.regular(11))
                            .foregroundColor(Color.CT.textDim)
                            .lineLimit(1)
                    }
                    if chat.isPinned && chat.unreadCount == 0 {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10, weight: .regular))
                            .foregroundColor(Color.CT.textDim)
                    }
                }

                HStack(alignment: .center, spacing: CTLayout.inlinePad) {
                    if let lastMessage = chat.lastMessageText {
                        Text(Chat.formatPreviewText(lastMessage))
                            .font(CTFont.regular(12))
                            .foregroundColor(Color.CT.textDim)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if chat.unreadCount > 0 {
                        Text(chat.unreadCount < 10000 ? "\(chat.unreadCount)" : "9999+")
                            .font(CTFont.bold(11))
                            .foregroundColor(Color.CT.bg)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.CT.accent)
                            .clipShape(CTShape.badge())
                            .animation(.easeInOut(duration: 0.2), value: chat.unreadCount)
                    }
                }
            }
        }
        .padding(.vertical, CTLayout.inlinePad)
        .contentShape(Rectangle())
        #if os(iOS)
        .contentShape(.contextMenuPreview, Rectangle())
        #endif
        .contextMenu { contextMenuContent }
    }

    @ViewBuilder
    private func displayNameView(for user: User) -> some View {
        let alias = user.localAlias?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let alias, !alias.isEmpty {
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
        } else {
            Text(user.resolvedDisplayName.uppercased())
                .font(CTFont.bold(13))
                .foregroundColor(Color.CT.text)
        }
    }

    @ViewBuilder
    private var avatarView: some View {
        let seed = user?.id ?? "?"
        let initials = initials(for: user)
        if let data = user?.avatarData,
           let platformImg = ImageHelper.imageFromData(data) {
            CTHexAvatar(initials: initials, image: Image(platformImage: platformImg), size: .medium, colorSeed: seed)
        } else {
            CTHexAvatar(initials: initials, size: .medium, colorSeed: seed)
        }
    }

    @ViewBuilder
    private var contextMenuContent: some View {
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

    private func initials(for user: User?) -> String {
        guard let name = user?.resolvedDisplayName else { return "?" }
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }
}
