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

struct CornerRadius {
    /// 8pt - Standard corner radius for cards, banners
    static let small: CGFloat = 8
    
    /// 12pt - Medium corner radius
    static let medium: CGFloat = 12
    
    /// 16pt - Large corner radius for message bubbles
    static let large: CGFloat = 16
    
    /// 20pt - Extra large corner radius
    static let extraLarge: CGFloat = 20
}

// MARK: - Shadow

struct ShadowStyle {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
    
    /// Light shadow for elevated cards
    static let card = ShadowStyle(
        color: Color.black.opacity(0.1),
        radius: 4,
        x: 0,
        y: 2
    )
    
    /// Subtle shadow for input bars
    static let inputBar = ShadowStyle(
        color: Color.black.opacity(0.1),
        radius: 2,
        x: 0,
        y: 1
    )
    
    /// No shadow
    static let none = ShadowStyle(
        color: Color.clear,
        radius: 0,
        x: 0,
        y: 0
    )
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

    /// Brand colors from Assets catalog
    struct AppBrand {
        /// Primary action color — buttons, CTAs (ButtonColor asset)
        static var button: Color { Color("ButtonColor") }
        /// Secondary accent — CustomTeal: icons, links, interactive elements
        static var second: Color { Color("CustomTeal") }
        /// Tertiary accent — StillGreen: success, delivered, positive states
        static var third: Color { Color("StillGreen") }
    }

    /// Standard background colors
    struct AppBackground {
        /// Primary app background (AppBackgroundPrimary asset)
        static var primary: Color { Color("AppBackgroundPrimary") }
        /// Secondary background (slightly gray)
        static var secondary: Color { Color(uiColor: .systemGray6) }
        /// Clear background
        static var clear: Color { Color.clear }
    }

    /// Standard text colors
    struct AppText {
        /// Primary text color
        static var primary: Color { Color.primary }
        /// Secondary text color
        static var secondary: Color { Color.secondary }
        /// Accent color (AccentColor asset)
        static var accent: Color { Color.accentColor }
        /// Text on colored surfaces (buttons, filled bubbles)
        static var onAccent: Color { Color.white }
        /// Red for errors
        static var error: Color { Color.red }
    }

    /// Semantic status colors
    struct AppStatus {
        /// Success / delivered / connected — uses StillGreen brand color
        static var success: Color { Color.AppBrand.third }
        static var error: Color { Color.red }
        static var warning: Color { Color.orange }
        /// Info / action / interactive — uses CustomTeal brand color
        static var info: Color { Color.AppBrand.second }
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
