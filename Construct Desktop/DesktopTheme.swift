//
//  DesktopTheme.swift
//  Construct Desktop
//
//  Design tokens for the macOS app.
//  Precision-tool aesthetic: cold dark background, single electric-blue accent,
//  data on foreground. Inspired by Linear / Vercel dashboard.
//

import SwiftUI

enum DesktopTheme {

    // MARK: - Background layers

    /// Primary app background — near-black with cold blue undertone
    static let backgroundPrimary   = Color(hex: "#0D0D10")
    /// Sidebar / panel surface (same bg, differentiated only by separator)
    static let backgroundPanel     = Color(hex: "#0D0D10")
    /// Elevated surfaces: popovers, sheets, context menus
    static let backgroundElevated  = Color(hex: "#16161A")
    /// Subtle row hover / selection background
    static let backgroundHover     = Color.white.opacity(0.04)
    /// Active chat row tint
    static let backgroundActive    = Color(hex: "#00D4FF").opacity(0.08)

    // MARK: - Accent

    /// Primary accent — Electric Blue/Cyan
    static let accent              = Color(hex: "#00D4FF")
    /// Accent at reduced opacity for backgrounds
    static let accentMuted         = Color(hex: "#00D4FF").opacity(0.15)
    /// Destructive
    static let destructive         = Color(hex: "#FF4D6A")

    // MARK: - Text

    static let textPrimary         = Color.white.opacity(0.90)
    static let textSecondary       = Color.white.opacity(0.45)
    static let textTertiary        = Color.white.opacity(0.25)

    // MARK: - Separators

    static let separator           = Color.white.opacity(0.08)
    static let separatorStrong     = Color.white.opacity(0.14)

    // MARK: - Message bubbles

    /// Outgoing bubble — very subtle accent tint, not harsh
    static let bubbleOutgoing      = Color(hex: "#00D4FF").opacity(0.10)
    /// Incoming bubble
    static let bubbleIncoming      = Color.white.opacity(0.06)

    // MARK: - Left-rail active indicator

    static let activeBorderWidth: CGFloat = 2
    static let activeBorderColor   = Color(hex: "#00D4FF")

    // MARK: - Typography

    /// Monospaced style for IDs, timestamps, session keys
    static func monoFont(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Color from hex

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6:
            (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (0, 0, 0)
        }
        self.init(
            red:   Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255
        )
    }
}

// MARK: - Active chat row modifier

struct DesktopActiveRowModifier: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .background(isActive ? DesktopTheme.backgroundActive : Color.clear)
            .overlay(alignment: .leading) {
                if isActive {
                    Rectangle()
                        .fill(DesktopTheme.activeBorderColor)
                        .frame(width: DesktopTheme.activeBorderWidth)
                }
            }
    }
}

extension View {
    func desktopActiveRow(_ isActive: Bool) -> some View {
        modifier(DesktopActiveRowModifier(isActive: isActive))
    }
}
