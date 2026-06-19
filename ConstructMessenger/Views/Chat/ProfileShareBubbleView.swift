//
//  ProfileShareBubbleView.swift
//  Construct Messenger
//

import SwiftUI
import Combine

struct ProfileShareBubbleView: View {
    let profileData: ProfileShareData

    private var initials: String {
        profileData.displayName
            .components(separatedBy: .whitespaces)
            .compactMap { $0.first.map(String.init) }
            .prefix(2)
            .joined()
            .uppercased()
    }

    var body: some View {
        HStack(spacing: 10) {
            // Avatar
            if let avatarData = profileData.avatarData,
               let imageData = Data(base64Encoded: avatarData),
               let uiImage = PlatformImage(data: imageData)
            {
                CTHexAvatar(
                    initials: initials,
                    image: Image(platformImage: uiImage),
                    size: .large
                )
            } else {
                CTHexAvatar(
                    initials: initials,
                    image: nil,
                    size: .large,
                    colorSeed: profileData.displayName
                )
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(profileData.displayName)
                    .font(CTFont.bold(13))
                    .foregroundColor(Color.CT.text)
                    .lineLimit(1)

                Text(LocalizedStringKey("shared_profile"))
                    .font(CTFont.regular(11))
                    .foregroundColor(Color.CT.textDim)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(CTMessageBubbleTheme.incomingBackground)
        .ctNoiseBorder()
    }
}

#Preview {
    VStack(spacing: 8) {
        ProfileShareBubbleView(profileData: ProfileShareData(
            displayName: "Alice Wonderland",
            avatarMediaId: nil, avatarMediaUrl: nil,
            avatarMediaKey: nil, avatarMediaType: nil,
            timestamp: 0
        ))
        ProfileShareBubbleView(profileData: ProfileShareData(
            displayName: "B",
            avatarMediaId: nil, avatarMediaUrl: nil,
            avatarMediaKey: nil, avatarMediaType: nil,
            timestamp: 0
        ))
    }
    .padding()
    .background(Color.CT.bg)
}
