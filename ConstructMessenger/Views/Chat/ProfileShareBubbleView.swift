//
//  ProfileShareBubbleView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import SwiftUI

struct ProfileShareBubbleView: View {
    let profileData: ProfileShareData

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                // Avatar placeholder or image
                if let avatarData = profileData.avatarData,
                   let imageData = Data(base64Encoded: avatarData),
                   let uiImage = PlatformImage(data: imageData)
                {
                    Image(platformImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 60, height: 60)
                        .clipShape(AvatarStyle.avatarShape(AvatarStyle.bubbleSize))
                } else {
                    AvatarStyle.avatarShape(AvatarStyle.bubbleSize)
                        .fill(Color.blue.opacity(0.2))
                        .frame(width: 60, height: 60)
                        .overlay(
                            Text(String(profileData.displayName.prefix(1)).uppercased())
                                .font(.title2)
                                .foregroundColor(Color.blue)
                        )
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(profileData.displayName)
                        .font(.headline)
                        .foregroundColor(.primary)

                    Text(LocalizedStringKey("shared_profile"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
        }
        .padding(12)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(16)
    }
}

