//
//  HexagonAvatarView.swift
//  Construct Messenger
//
//  Hexagonal avatar component for the Construct visual language.
//
//  Usage:
//    HexagonAvatarView(userId: contact.id, displayName: contact.name, size: 44)
//    HexagonAvatarView(userId: contact.id, image: contact.avatar, size: 44, isActive: true)
//

import SwiftUI

// MARK: - Hexagon Shape

/// A regular flat-top hexagon. Works as a SwiftUI clip shape and stroke shape.
struct HexagonShape: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        for i in 0..<6 {
            // Flat-top: first vertex at 0° (right side), rotate 30° for pointy-top
            let angle = CGFloat(i) * .pi / 3 - .pi / 6
            let point = CGPoint(
                x: center.x + radius * cos(angle),
                y: center.y + radius * sin(angle)
            )
            i == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }
}

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

// MARK: - HexagonAvatarView

/// Reusable hexagonal avatar supporting image or initials fallback.
///
/// - Clips the image/initials to a hexagon shape.
/// - Draws a 1.5pt stroke in the user's deterministic accent color.
/// - Optionally dims the stroke for inactive contacts.
/// - Shows a small green presence dot when `isOnline` is true.
struct HexagonAvatarView: View {

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
            HexagonAvatarView(
                userId: "alice-123",
                displayName: "Alice",
                size: 52,
                isActive: true,
                isOnline: true
            )

            // Initials, inactive
            HexagonAvatarView(
                userId: "bob-456",
                displayName: "Bob Smith",
                size: 52
            )

            // Initials, online
            HexagonAvatarView(
                userId: "carol-789",
                displayName: "Carol",
                size: 52,
                isOnline: true
            )

            // Single word name
            HexagonAvatarView(
                userId: "dave-000",
                displayName: "Dave",
                size: 52
            )
        }

        HStack(spacing: 12) {
            // Small size (chat list)
            ForEach(["u1", "u2", "u3", "u4", "u5"], id: \.self) { id in
                HexagonAvatarView(
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
