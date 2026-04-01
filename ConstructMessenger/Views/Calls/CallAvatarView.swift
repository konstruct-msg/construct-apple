//
//  CallAvatarView.swift
//  Construct Messenger
//
//  Circular avatar for calls screens — matches AvatarStyle used app-wide.
//

import SwiftUI

struct CallAvatarView: View {
    let userId: String
    let displayName: String
    let size: CGFloat

    var body: some View {
        let accent = Color.hexagonAccent(for: userId)
        let initials = Self.initials(from: displayName)

        AvatarStyle.avatarShape(size)
            .fill(accent.opacity(0.15))
            .frame(width: size, height: size)
            .overlay {
                Text(initials)
                    .font(ConstructFont.mono(size * 0.3, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .overlay {
                AvatarStyle.avatarShape(size)
                    .strokeBorder(Color.Construct.dim, lineWidth: 1.5)
            }
    }

    private static func initials(from name: String) -> String {
        let words = name.split(separator: " ").prefix(2)
        return words.compactMap { $0.first.map { String($0).uppercased() } }.joined()
    }
}
