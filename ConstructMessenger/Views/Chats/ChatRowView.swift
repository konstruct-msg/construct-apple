//
//  ChatRowView.swift
//  Construct Messenger
//
//  Flat, grid-aligned row — no cards, no shadows, hairline divider.
//

import SwiftUI

struct ChatRowView: View {
    @ObservedObject var chat: Chat

    var body: some View {
        HStack(spacing: 14) {
            // Square avatar block
            avatarBlock
                .frame(width: AvatarStyle.chatSize, height: AvatarStyle.chatSize)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text((chat.otherUser?.displayName ?? chat.otherUser?.username ?? "—").uppercased())
                        .font(.system(.subheadline, design: .default).weight(.semibold))
                        .lineLimit(1)

                    Spacer()

                    if let ts = chat.lastMessageTime {
                        Text(ts, style: .time)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }

                if let preview = chat.lastMessageText {
                    Text(Chat.formatPreviewText(preview))
                        .font(.system(.footnote, design: .default))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // Bottom hairline — replaces List separator which can't be customised to 0.5pt
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.AppBorder.hairline)
                .frame(height: 0.5)
                .padding(.leading, 16 + AvatarStyle.chatSize + 14)
        }
    }

    // MARK: - Avatar

    @ViewBuilder
    private var avatarBlock: some View {
        if let data = chat.otherUser?.avatarData,
           let img  = ImageHelper.imageFromData(data) {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .clipped()
        } else {
            Rectangle()
                .fill(Color.AppBrand.second.opacity(0.15))
                .overlay(
                    Text(initials)
                        .font(.system(.callout, design: .monospaced).weight(.medium))
                        .foregroundColor(Color.AppBrand.second)
                )
        }
    }

    private var initials: String {
        let name = chat.otherUser?.displayName ?? chat.otherUser?.username ?? "?"
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return (String(parts[0].prefix(1)) + String(parts[1].prefix(1))).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }
}

