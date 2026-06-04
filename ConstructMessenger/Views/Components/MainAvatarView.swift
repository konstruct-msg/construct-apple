//
//  MainAvatarView.swift
//  Construct Messenger
//

import SwiftUI


// MARK: - Deterministic accent color

extension Color {
    /// Derives a consistent accent color from a user ID (or any stable string).
    /// Uses the same algorithm as the design concept: hsl(hash(id) % 360, 60%, 55%).
    static func hexagonAccent(for id: String) -> Color {
        var hash: UInt32 = 5381
        for scalar in id.unicodeScalars {
            hash = (hash &<< 5) &+ hash &+ scalar.value
        }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.60, brightness: 0.55)
    }
}

// MARK: - AvatarView

struct MainAvatarView: View {

    // MARK: Parameters

    let userId: String
    var displayName: String = ""
    var image: PlatformImage? = nil
    var size: CGFloat = 44
    var isActive: Bool = false    // currently selected / foreground chat
    var isOnline: Bool = false    // presence indicator
    var strokeWidth: CGFloat = 1.5

    // MARK: Derived

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

    // MARK: Body

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            hexagonContent
                .frame(width: size, height: size)

            if isOnline {
                presenceDot
            }
        }
    }

    // MARK: - Hexagon content

    @ViewBuilder
    private var hexagonContent: some View {
        ZStack {
            // Fill layer — image or initials
            if let image {
                imageLayer(image)
            } else {
                initialsLayer
            }

            // Stroke ring
            Circle()
                .stroke(
                    accentColor.opacity(isActive ? 1.0 : 0.45),
                    lineWidth: strokeWidth
                )

            // Active glow — extra outer ring
            if isActive {
                Circle()
                    .stroke(accentColor.opacity(0.25), lineWidth: 3)
                    .blur(radius: 2)
            }
        }
        .clipShape(Circle())
        .contentShape(Circle())
    }

    // MARK: - Image layer

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

    // MARK: - Initials layer

    private var initialsLayer: some View {
        ZStack {
            // Background — subtle tint of the accent color
            accentColor.opacity(0.12)

            Text(initials)
                .font(.system(size: size * 0.33, weight: .medium, design: .monospaced))
                .foregroundStyle(accentColor)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
        .frame(width: size, height: size)
    }

    // MARK: - Presence dot

    private var presenceDot: some View {
        Circle()
            .fill(Color.green)
            .frame(width: size * 0.22, height: size * 0.22)
            .overlay(
                Circle()
                    .stroke(Color.AppBackground.primary, lineWidth: 1.5)
            )
            .offset(x: 2, y: 2)
    }
}

// MARK: - Preview

#Preview("Hexagon Avatars") {
    VStack(spacing: 24) {
        HStack(spacing: 20) {
            // Image avatar
            MainAvatarView(
                userId: "alice-123",
                displayName: "Alice",
                size: 52,
                isActive: true,
                isOnline: true
            )

            // Initials, inactive
            MainAvatarView(
                userId: "bob-456",
                displayName: "Bob Smith",
                size: 52
            )

            // Initials, online
            MainAvatarView(
                userId: "carol-789",
                displayName: "Carol",
                size: 52,
                isOnline: true
            )

            // Single word name
            MainAvatarView(
                userId: "dave-000",
                displayName: "Dave",
                size: 52
            )
        }

        HStack(spacing: 12) {
            // Small size (chat list)
            ForEach(["u1", "u2", "u3", "u4", "u5"], id: \.self) { id in
                MainAvatarView(
                    userId: id,
                    displayName: id.uppercased(),
                    size: 36
                )
            }
        }
    }
    .padding(32)
    .background(Color(hue: 0, saturation: 0, brightness: 0.04))
}
