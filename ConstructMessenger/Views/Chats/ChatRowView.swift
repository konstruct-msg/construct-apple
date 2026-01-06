//
//  ChatRowView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import SwiftUI

struct ChatRowView: View {
    let chat: Chat

    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            Group {
                if let avatarData = chat.otherUser?.avatarData,
                   let avatarImage = ImageHelper.imageFromData(avatarData) {
                    Image(uiImage: avatarImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 50, height: 50)
                        .clipShape(Circle())
                } else {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 50, height: 50)
                        .overlay {
                            Text(initials)
                                .foregroundColor(.white)
                                .fontWeight(.semibold)
                        }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(chat.otherUser?.displayName ?? NSLocalizedString("unknown", comment: "Unknown user"))
                    .fontWeight(.semibold)

                if let lastMessage = chat.lastMessageText {
                    Text(lastMessage)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

        }
        .padding(.vertical, 4)
    }

    private var initials: String {
        guard let displayName = chat.otherUser?.displayName else { return "?" }
        let components = displayName.split(separator: " ")
        if components.count >= 2 {
            return String(components[0].prefix(1) + components[1].prefix(1)).uppercased()
        }
        return String(displayName.prefix(2)).uppercased()
    }
}
