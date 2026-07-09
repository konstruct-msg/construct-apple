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

// MARK: - Identicon

/// Deterministic dot-matrix identicon generated from a stable seed (userId / UUID).
/// 5×5 mirrored grid of dots — left half is hashed, right half mirrors it, giving a
/// pleasant symmetric shape. Colour reuses `Color.hexagonAccent(for:)` so the pattern
/// and the surrounding ring share one per-identity hue. Drawn in a single `Canvas`.
struct IdenticonView: View {
    let seed: String
    var gridSize: Int = 5

    /// How densely the grid fills, on a 0...15 scale (4 bits per cell).
    ///
    /// Each cell reads a 4-bit nibble of the hash (value `0...15`) and is filled when that
    /// value is `>= densityThreshold`. So the threshold is the *minimum nibble that counts as
    /// "on"* — lower = denser, higher = sparser:
    ///   - `8`  → ~50% filled (the visual default, evenly balanced)
    ///   - `6`  → ~62% filled (busier, more solid-looking dots)
    ///   - `10` → ~37% filled (airier, more negative space)
    ///
    /// Why you'd ever touch this:
    ///   1. **Legibility at a new size.** At larger avatar sizes a denser grid (lower value)
    ///      can look richer; at very small sizes a sparser grid (higher value) avoids the dots
    ///      merging into a blob. If we add a size noticeably different from today's 32–80pt,
    ///      retune here rather than fighting it with dot radius.
    ///   2. **Distinctiveness across the user base.** ~50% is the sweet spot for telling
    ///      identities apart. If real-world avatars ever read as too uniform/noisy, nudge it.
    ///   3. **Background contrast changes.** The dots sit on a 12%-accent tint; if that
    ///      backdrop changes, density may need a tweak to keep the pattern readable.
    /// It does *not* clamp the rare near-empty/near-full outcome — that would need a post-build
    /// count check, not a threshold shift.
    var densityThreshold: UInt64 = 8

    private var accentColor: Color { .hexagonAccent(for: seed) }

    /// 64-bit FNV-1a over the seed bytes. Distinct from the DJB2 hash used for colour,
    /// so the pattern is not correlated with the hue.
    private var patternHash: UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// Symmetric on/off grid: only the left half (incl. centre column) is hashed,
    /// the right half mirrors it. Each cell consumes a 4-bit nibble of the hash and is
    /// filled when that nibble `>= densityThreshold` (see `densityThreshold` docs).
    private var cells: [[Bool]] {
        let cols = gridSize
        let halfCols = (cols + 1) / 2
        let hash = patternHash
        var grid = Array(repeating: Array(repeating: false, count: cols), count: gridSize)
        // 64 bits / 4-bit nibbles = 16 cells available; a 5×5 grid hashes 15 (3×5), fits.
        var nibble = 0
        for r in 0..<gridSize {
            for c in 0..<halfCols {
                let value = (hash >> UInt64((nibble % 16) * 4)) & 0xF
                let on = value >= densityThreshold
                grid[r][c] = on
                grid[r][cols - 1 - c] = on
                nibble += 1
            }
        }
        return grid
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            // Inset so corner dots stay inside the circular clip.
            let inset = side * 0.14
            let cell = (side - inset * 2) / CGFloat(gridSize)
            let dotRadius = cell * 0.34
            let grid = cells
            Canvas { ctx, _ in
                for r in 0..<gridSize {
                    for c in 0..<gridSize where grid[r][c] {
                        let cx = inset + (CGFloat(c) + 0.5) * cell
                        let cy = inset + (CGFloat(r) + 0.5) * cell
                        let rect = CGRect(x: cx - dotRadius, y: cy - dotRadius,
                                          width: dotRadius * 2, height: dotRadius * 2)
                        ctx.fill(Path(ellipseIn: rect), with: .color(accentColor))
                    }
                }
            }
        }
        .allowsHitTesting(false)
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
            // Fill layer — image or generated identicon
            if let image {
                imageLayer(image)
            } else {
                identiconLayer
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

    // MARK: - Identicon layer

    private var identiconLayer: some View {
        ZStack {
            // Background — subtle tint of the accent color
            accentColor.opacity(0.12)

            IdenticonView(seed: userId)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(displayName.isEmpty ? Text(verbatim: userId) : Text(displayName))
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
