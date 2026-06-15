//
//  Avatars.swift
//  ConstructUI
//
//  Copied from the app's MainAvatarView.swift. Adapted for the package:
//   - `hexagonAccent(for:)` lives in Support.swift (removed the duplicate here)
//   - `Color.AppBackground.primary` (app-only) → `Color.CT.bg`
//  Driven purely by value types (userId / displayName / image), so it previews
//  with mock data — no app models or services.
//

import SwiftUI

struct MainAvatarView: View {

    let userId: String
    var displayName: String = ""
    var image: PlatformImage? = nil
    var size: CGFloat = 44
    var isActive: Bool = false    // currently selected / foreground chat
    var isOnline: Bool = false    // presence indicator
    var strokeWidth: CGFloat = 1.5

    private var accentColor: Color { .hexagonAccent(for: userId) }

    private var initials: String {
        let words = displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        switch words.count {
        case 0:  return "?"
        case 1:  return String(words[0].prefix(2)).uppercased()
        default: return (String(words[0].prefix(1)) + String(words[1].prefix(1))).uppercased()
        }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            hexagonContent
                .frame(width: size, height: size)

            if isOnline {
                presenceDot
            }
        }
    }

    @ViewBuilder
    private var hexagonContent: some View {
        ZStack {
            if let image {
                imageLayer(image)
            } else {
                initialsLayer
            }

            Circle()
                .stroke(
                    accentColor.opacity(isActive ? 1.0 : 0.45),
                    lineWidth: strokeWidth
                )

            if isActive {
                Circle()
                    .stroke(accentColor.opacity(0.25), lineWidth: 3)
                    .blur(radius: 2)
            }
        }
        .clipShape(Circle())
        .contentShape(Circle())
    }

    private func imageLayer(_ image: PlatformImage) -> some View {
        #if canImport(UIKit)
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
        #else
        Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
        #endif
    }

    private var initialsLayer: some View {
        ZStack {
            accentColor.opacity(0.12)

            Text(initials)
                .font(.system(size: size * 0.33, weight: .medium, design: .monospaced))
                .foregroundStyle(accentColor)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
        .frame(width: size, height: size)
    }

    private var presenceDot: some View {
        Circle()
            .fill(Color.green)
            .frame(width: size * 0.22, height: size * 0.22)
            .overlay(
                Circle()
                    .stroke(Color.CT.bg, lineWidth: 1.5)
            )
            .offset(x: 2, y: 2)
    }
}

#Preview("Hexagon Avatars") {
    VStack(spacing: 24) {
        HStack(spacing: 20) {
            MainAvatarView(userId: "alice-123", displayName: "Alice", size: 52, isActive: true, isOnline: true)
            MainAvatarView(userId: "bob-456", displayName: "Bob Smith", size: 52)
            MainAvatarView(userId: "carol-789", displayName: "Carol", size: 52, isOnline: true)
            MainAvatarView(userId: "dave-000", displayName: "Dave", size: 52)
        }

        HStack(spacing: 12) {
            ForEach(["u1", "u2", "u3", "u4", "u5"], id: \.self) { id in
                MainAvatarView(userId: id, displayName: id.uppercased(), size: 36)
            }
        }
    }
    .padding(32)
    .background(Color.CT.bg)
}
