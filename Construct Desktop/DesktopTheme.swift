//
//  DesktopTheme.swift
//  Construct Desktop
//
//  Compatibility shim — all tokens now delegate to the shared CT design system.
//  New code should use Color.CT.* and CTFont directly.
//

import SwiftUI

enum DesktopTheme {

    // MARK: - Backgrounds (→ CT)
    static let backgroundPrimary   = Color.CT.bg
    static let backgroundPanel     = Color.CT.bg
    static let backgroundElevated  = Color.CT.bgMsg
    static let backgroundHover     = Color.CT.noise.opacity(0.5)
    static let backgroundActive    = Color.CT.accent.opacity(0.08)

    // MARK: - Accent (→ CT)
    static let accent              = Color.CT.accent
    static let accentMuted         = Color.CT.accent.opacity(0.15)
    static let destructive         = Color.CT.danger

    // MARK: - Text (→ CT)
    static let textPrimary         = Color.CT.text
    static let textSecondary       = Color.CT.textDim
    static let textTertiary        = Color.CT.textDim.opacity(0.55)

    // MARK: - Separators (→ CT)
    static let separator           = Color.CT.noise
    static let separatorStrong     = Color.CT.noise.opacity(1.6)

    // MARK: - No more message bubbles — kept for compile compat only
    static let bubbleOutgoing      = Color.CT.accent.opacity(0.10)
    static let bubbleIncoming      = Color.CT.noise.opacity(0.5)

    // MARK: - Active chat row indicator
    static let activeBorderWidth: CGFloat = 2
    static let activeBorderColor   = Color.CT.accent

    // MARK: - Typography (→ CTFont / JetBrains Mono)
    static func monoFont(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch weight {
        case .bold, .heavy, .black:        return CTFont.bold(size)
        case .medium, .semibold:           return CTFont.medium(size)
        default:                           return CTFont.regular(size)
        }
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
