//
//  CallAvatarView.swift
//  Construct Messenger
//
//  Hexagonal avatar for calls screens.
//

import SwiftUI

struct CallAvatarView: View {
    let userId: String
    let displayName: String
    let size: CGFloat

    var body: some View {
        HexagonAvatarView(
            userId: userId,
            displayName: displayName,
            size: size
        )
    }

    private static func initials(from name: String) -> String {
        let words = name.split(separator: " ").prefix(2)
        return words.compactMap { $0.first.map { String($0).uppercased() } }.joined()
    }
}
