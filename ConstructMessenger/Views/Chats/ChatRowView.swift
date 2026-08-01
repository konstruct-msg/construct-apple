//
//  ChatRowView.swift
//  Construct Messenger
//

import SwiftUI
import Combine
import CoreData

struct ChatRowView: View {
    @ObservedObject var chat: Chat

    var body: some View {
        // Profile shares update `User` (displayName, avatarData), not `Chat`.
        // Observing Chat alone does not refresh when a related User changes.
        // Fetch the peer by id so Core Data attribute updates drive the row.
        if let userId = chat.otherUser?.id, !userId.isEmpty {
            ChatRowBody(chat: chat, userId: userId)
        } else {
            ChatRowOrphanBody(chat: chat)
        }
    }

    private static let rowTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    /// Short date for rows that are not from today — "Вчера" / "Yesterday" where the
    /// system offers it, otherwise a numeric date.
    private static let rowDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    /// Time for today's rows, date for everything older.
    ///
    /// It used to be time-only for every row: `doesRelativeDateFormatting` is a no-op when
    /// `dateStyle == .none`, so a week-old conversation and one from a minute ago rendered
    /// as identical bare clock times — and a row stamped with a *future* time looked
    /// completely ordinary, which is part of why a frozen preview was so hard to spot.
    static func rowTimestampText(_ date: Date, now: Date = Date()) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return rowTimeFormatter.string(from: date)
        }
        return rowDateFormatter.string(from: date)
    }
}

// MARK: - Row body

private struct ChatRowBody: View {
    @ObservedObject var chat: Chat
    @FetchRequest private var users: FetchedResults<User>

    init(chat: Chat, userId: String) {
        self.chat = chat
        _users = FetchRequest(
            sortDescriptors: [],
            predicate: NSPredicate(format: "id == %@", userId),
            animation: .default
        )
    }

    var body: some View {
        if let user = users.first {
            ChatRowWithUser(chat: chat, user: user)
        } else if let fallback = chat.otherUser {
            ChatRowWithUser(chat: chat, user: fallback)
        } else {
            ChatRowOrphanBody(chat: chat)
        }
    }
}

private struct ChatRowWithUser: View {
    @ObservedObject var chat: Chat
    @ObservedObject var user: User

    var body: some View {
        ChatRowLayout(chat: chat, user: user)
            // Bust any stale SwiftUI identity when profile *or preview* fields change.
            // Omitting lastMessageText/Time left rows frozen after Core Data advanced
            // while NSManagedObject objectWillChange stayed silent (list under NavStack).
            .id(rowIdentity)
    }

    private var rowIdentity: String {
        let previewTs = chat.lastMessageTime.map { String($0.timeIntervalSince1970) } ?? "nil"
        return "\(chat.id)|\(user.resolvedDisplayName)|\(user.avatarData?.count ?? 0)|\(user.isSharingWithMe)|\(chat.unreadCount)|\(chat.isPinned)|\(chat.lastMessageText ?? "")|\(previewTs)"
    }
}

/// Rare fallback when `chat.otherUser` is nil — observes Chat only.
private struct ChatRowOrphanBody: View {
    @ObservedObject var chat: Chat

    var body: some View {
        ChatRowLayout(chat: chat, user: nil)
            .id(orphanIdentity)
    }

    private var orphanIdentity: String {
        let previewTs = chat.lastMessageTime.map { String($0.timeIntervalSince1970) } ?? "nil"
        return "\(chat.id)|\(chat.unreadCount)|\(chat.lastMessageText ?? "")|\(previewTs)"
    }
}

// MARK: - Shared layout

private struct ChatRowLayout: View {
    /// Must observe Chat: preview/pin/unread land on this object. A plain `let` + stable
    /// `.id` without preview fields left the subtitle stuck after local sends.
    @ObservedObject var chat: Chat
    var user: User?

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
                        Text(ChatRowView.rowTimestampText(ts))
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
                            // Explicit dependency so SwiftUI cannot elide the Text when
                            // only the denormalized preview string changes.
                            .animation(nil, value: lastMessage)
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
        } else {
            // Profile-shared name → username → generated (see User.resolvedDisplayName).
            Text(user.resolvedDisplayName)
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
