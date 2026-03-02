//
//  UIConstants.swift
//  Construct Messenger
//
//  Centralized UI configuration: spacing, animations, colors, fonts
//  Created on 30.01.2026 (Week 1 refactoring)
//

import SwiftUI

// MARK: - Spacing Constants

struct Spacing {
    /// 4pt - Compact spacing within message groups
    static let compact: CGFloat = 4
    
    /// 8pt - Standard small spacing
    static let small: CGFloat = 8
    
    /// 12pt - Standard spacing between message groups
    static let standard: CGFloat = 12
    
    /// 16pt - Medium spacing
    static let medium: CGFloat = 16
    
    /// 24pt - Large spacing
    static let large: CGFloat = 24
    
    /// 32pt - Extra large spacing
    static let extraLarge: CGFloat = 32
}

// MARK: - Corner Radius
// Flat design: no rounding by default. Use micro (2pt) only where hard corners
// feel uncomfortable (e.g. inline tags). Message bubbles: 0.

struct CornerRadius {
    /// 0pt — Flat, no rounding (default for surfaces and bubbles)
    static let none: CGFloat = 0

    /// 2pt — Micro rounding for inline labels / badges only
    static let micro: CGFloat = 2

    /// Legacy aliases kept so existing call-sites compile without changes.
    /// Prefer CornerRadius.none or CornerRadius.micro in new code.
    static let small: CGFloat = 2
    static let medium: CGFloat = 2
    static let large: CGFloat = 0
    static let extraLarge: CGFloat = 0
}

// MARK: - Shadow
// All shadows disabled — flat design language.

struct ShadowStyle {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat

    static let card     = ShadowStyle(color: .clear, radius: 0, x: 0, y: 0)
    static let inputBar = ShadowStyle(color: .clear, radius: 0, x: 0, y: 0)
    static let none     = ShadowStyle(color: .clear, radius: 0, x: 0, y: 0)
}

// MARK: - Animation Duration

struct AnimationDuration {
    /// 0.1s - Very quick animations
    static let veryQuick: TimeInterval = 0.1
    
    /// 0.2s - Quick animations (search scroll)
    static let quick: TimeInterval = 0.2
    
    /// 0.25s - Standard animation duration
    static let standard: TimeInterval = 0.25
    
    /// 0.3s - Slightly slower animations (dismissal)
    static let medium: TimeInterval = 0.3
    
    /// 0.5s - Slow animations (message send scroll)
    static let slow: TimeInterval = 0.5
}

// MARK: - Opacity

struct OpacityLevel {
    /// 0.1 - Very subtle
    static let verySubtle: Double = 0.1
    
    /// 0.2 - Subtle background tint
    static let subtle: Double = 0.2
    
    /// 0.5 - Medium transparency
    static let medium: Double = 0.5
    
    /// 0.7 - Mostly opaque
    static let high: Double = 0.7
    
    /// 0.95 - Almost opaque (status banners)
    static let veryHigh: Double = 0.95
}

// MARK: - ChatView Specific Constants

struct ChatViewConstants {
    /// Swipe-to-dismiss gesture threshold
    struct Gesture {
        /// Maximum drag distance (20% of screen width)
        static let maxDragRatio: CGFloat = 0.2
        
        /// Minimum drag to trigger dismiss (100pt or 30% of screen)
        static let dismissThreshold: CGFloat = 100
        static let dismissThresholdRatio: CGFloat = 0.3
        
        /// Spring animation parameters for dismissal
        static let dismissSpringResponse: Double = 0.3
        static let dismissSpringDamping: Double = 0.8
    }
    
    /// Status banner configuration
    struct StatusBanner {
        /// Vertical padding inside banner
        static let verticalPadding: CGFloat = 8
        
        /// Horizontal padding inside banner
        static let horizontalPadding: CGFloat = 12
        
        /// Top spacing from navbar
        static let topSpacing: CGFloat = 4
        
        /// Background opacity
        static let backgroundOpacity: Double = 0.95
        
        /// Tint color opacity
        static let tintOpacity: Double = 0.2
        
        /// Loading indicator scale
        static let loadingIndicatorScale: CGFloat = 0.7
    }
    
    /// Search functionality delays
    struct SearchDelay {
        /// Delay before scrolling to first search result
        static let scrollToResult: TimeInterval = 0.2
    }
    
    /// Message sending delays
    struct MessageDelay {
        /// Delay after sending before scrolling (for rendering)
        static let scrollAfterSend: TimeInterval = 0.5
        
        /// Delay for media messages to render
        static let mediaRender: TimeInterval = 0.1
    }
}

// MARK: - Font Styles

struct FontStyle {
    /// Caption font for secondary text
    static let caption = Font.caption
    
    /// Body font for regular text
    static let body = Font.body
    
    /// Headline for titles
    static let headline = Font.headline
    
    /// Title for larger headings
    static let title = Font.title2
}

// MARK: - Container Width Environment Key

private struct ContainerWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 390 // Safe default for iPhone 15 Pro
}

extension EnvironmentValues {
    var containerWidth: CGFloat {
        get { self[ContainerWidthKey.self] }
        set { self[ContainerWidthKey.self] = newValue }
    }
}

// MARK: - Color Extensions

extension Color {

    // MARK: Brand / Accent
    // Two unsaturated accents: cyan and amber/orange.
    // Avoid using these for decorative purposes — reserve for state and interaction.

    struct AppBrand {
        /// Cyan — interactive elements, active state, outgoing message tint.
        /// Desaturated to avoid visual noise.
        static let second = Color(red: 0.25, green: 0.75, blue: 0.78)   // #40BFC7

        /// Amber — warnings, errors, pending states.
        static let third  = Color(red: 0.85, green: 0.55, blue: 0.22)   // #D98C38

        /// Primary action color (buttons, CTAs) — same as second for now.
        static var button: Color { second }
    }

    // MARK: Semantic status

    struct AppStatus {
        static var success: Color { AppBrand.second }
        static var error:   Color { Color(red: 0.85, green: 0.25, blue: 0.25) }
        static var warning: Color { AppBrand.third }
        static var info:    Color { AppBrand.second }
    }

    // MARK: Background

    struct AppBackground {
        /// Primary surface — system white (light) / pure black (dark).
        static var primary: Color { Color(.systemBackground) }

        /// Secondary surface — near-white in light mode, near-black in dark mode.
        static var secondary: Color { Color(.secondarySystemBackground) }

        /// Clear
        static var clear: Color { Color.clear }
    }

    // MARK: Text

    struct AppText {
        static var primary:   Color { Color.primary }
        static var secondary: Color { Color.secondary }
        static var accent:    Color { AppBrand.second }
        static var onAccent:  Color { Color.white }
        static var error:     Color { AppStatus.error }
    }

    // MARK: Divider / Border

    struct AppBorder {
        /// Standard thin separator line (0.5pt)
        static var hairline: Color { Color(.separator) }
        /// Slightly more visible line for section framing
        static var regular:  Color { Color(.opaqueSeparator) }
    }
}

// MARK: - View Extensions for Easy Usage

extension View {
    /// Apply card shadow style
    func cardShadow() -> some View {
        self.shadow(
            color: ShadowStyle.card.color,
            radius: ShadowStyle.card.radius,
            x: ShadowStyle.card.x,
            y: ShadowStyle.card.y
        )
    }
    
    /// Apply input bar shadow style
    func inputBarShadow() -> some View {
        self.shadow(
            color: ShadowStyle.inputBar.color,
            radius: ShadowStyle.inputBar.radius,
            x: ShadowStyle.inputBar.x,
            y: ShadowStyle.inputBar.y
        )
    }
    
    /// Apply standard corner radius
    func standardCornerRadius() -> some View {
        self.cornerRadius(CornerRadius.small)
    }
    
    /// Apply medium corner radius
    func mediumCornerRadius() -> some View {
        self.cornerRadius(CornerRadius.medium)
    }
}

// MARK: - QR Code Constants

struct QRCodeSize {
    static func standard(in containerWidth: CGFloat) -> CGFloat {
        min(containerWidth * 0.8, 350)
    }
    static let padding: CGFloat = 20
    static let cornerRadius: CGFloat = 20
    static let shadowRadius: CGFloat = 10
}
