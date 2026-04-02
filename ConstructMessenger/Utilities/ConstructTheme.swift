//
//  ConstructTheme.swift
//  Construct Messenger
//
//  Terminal design system — single source of truth.
//  iOS · macOS Desktop · TUI share the same aesthetic.
//
//  Usage:
//    Color.CT.accent          → brand blue
//    CTFont.bold(14)          → JetBrains Mono Bold 14pt
//    CTSymbol.back            → "[←]"
//    CTHexAvatar(initials: "AX", size: .medium)
//    CTNoise()                → ASCII noise background layer
//    CTNavBar(title: "CHATS", trailingSymbol: CTSymbol.add)
//    Text("hello").ctMessageBlock(outgoing: false)
//    myView.ctBackground()    → dark bg + noise layer
//
//  Design doc: /Documents/Konstruct/ASCII_style_design.md
//

import SwiftUI

// MARK: - Color Palette

extension Color {
    /// Terminal design palette. All new CT* views use these exclusively.
    struct CT {
        /// Near-black main background: #090909
        static let bg         = Color(hex: 0x090909)
        /// Incoming message block background: #111111
        static let bgMsg      = Color(hex: 0x111111)
        /// Outgoing message block / primary accent: #1A3FFF
        static let accent     = Color(hex: 0x1A3FFF)
        /// System messages, section headers, secondary accent: #4A6AFF
        static let accentDim  = Color(hex: 0x4A6AFF)
        /// Primary text: #E8E8E8
        static let text       = Color(hex: 0xE8E8E8)
        /// Timestamps, metadata, inactive: #555555
        static let textDim    = Color(hex: 0x555555)
        /// ASCII noise characters, thin dividers: #1E1E1E
        static let noise      = Color(hex: 0x1E1E1E)
        /// Destructive actions: #DC3C3C
        static let danger     = Color(hex: 0xDC3C3C)
    }
}

// MARK: - Typography

/// Thin wrapper around ConstructFont so CT* views need no direct dependency on UIConstants.
enum CTFont {
    static func regular(_ size: CGFloat) -> Font { ConstructFont.mono(size, weight: .regular) }
    static func medium(_ size: CGFloat)  -> Font { ConstructFont.mono(size, weight: .medium)  }
    static func bold(_ size: CGFloat)    -> Font { ConstructFont.mono(size, weight: .bold)    }
}

// MARK: - Symbol Table

/// All UI symbols as named constants. Never hardcode "[←]" inline.
enum CTSymbol {
    // Navigation
    static let back     = "[←]"
    static let forward  = "[→]"

    // Actions
    static let add      = "[+]"
    static let close    = "[×]"
    static let send     = "[→]"
    static let media    = "[◎]"
    static let menu     = "[***]"
    static let edit     = "[edit]"

    // Status
    static let ok          = "[✓]"
    static let read        = "[↵]"
    static let delivered   = "[✓✓]"
    static let error       = "[!]"
    static let online      = "[[ONLINE]]"
    static let cursor      = "_"

    // Tab bar
    static let tabChats    = "[⌂]"
    static let tabContacts = "[⊹]"
    static let tabSettings = "[cfg]"

    // Separators — call as functions for custom length
    static func thin(_ count: Int = 25)  -> String { String(repeating: "- ", count: count) }
    static func thick(_ count: Int = 25) -> String { String(repeating: "= ", count: count) }
}

// MARK: - Hexagonal Avatar Shape

struct CTHexShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cx = rect.midX, cy = rect.midY
        let r  = min(rect.width, rect.height) / 2
        var p  = Path()
        for i in 0..<6 {
            let a  = CGFloat(i) * .pi / 3 - .pi / 6
            let pt = CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        p.closeSubpath()
        return p
    }
}

struct CTHexAvatar: View {
    var initials: String
    var size: AvatarSize = .medium

    enum AvatarSize: CGFloat {
        case small  = 32   // reserved for group chats
        case medium = 40   // chat list rows
        case large  = 56   // settings main profile block
        case xlarge = 80   // profile detail screen
    }

    var body: some View {
        ZStack {
            CTHexShape()
                .fill(Color.CT.accent.opacity(0.18))
            CTHexShape()
                .stroke(Color.CT.accent, lineWidth: 1)
            Text(String(initials.prefix(2)).uppercased())
                .font(CTFont.bold(size.rawValue * 0.28))
                .foregroundColor(Color.CT.accent)
        }
        .frame(width: size.rawValue, height: size.rawValue)
    }
}

// MARK: - ASCII Noise Background

private let _ctNoiseChars: [Character] = [
    "@", "%", "#", "+", "-", "=", ":", ".", "*", "/", "\\", "(", ")", "|", "~", "^", "<", ">"
]

private struct _CTNoiseRNG {
    var state: Int
    init(seed: Int) { state = seed }
    mutating func next() -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return abs(state) % _ctNoiseChars.count
    }
}

/// Fullscreen ASCII noise texture layer. Place behind content with `.ignoresSafeArea()`.
/// Use via `.ctBackground()` modifier instead of composing manually.
struct CTNoise: View {
    var rows: Int    = 40
    var cols: Int    = 22
    var opacity: Double = 0.10

    private let grid: [[Character]]

    init(rows: Int = 40, cols: Int = 22, opacity: Double = 0.10) {
        self.rows    = rows
        self.cols    = cols
        self.opacity = opacity
        var rng = _CTNoiseRNG(seed: 42)
        grid = (0..<rows).map { _ in (0..<cols).map { _ in _ctNoiseChars[rng.next()] } }
    }

    var body: some View {
        GeometryReader { geo in
            let cw = geo.size.width  / CGFloat(cols)
            let ch = geo.size.height / CGFloat(rows)
            Canvas { ctx, _ in
                ctx.opacity = opacity
                for r in 0..<rows {
                    for c in 0..<cols {
                        ctx.draw(
                            Text(String(grid[r][c]))
                                .font(CTFont.regular(10))
                                .foregroundColor(Color.CT.noise),
                            at: CGPoint(x: CGFloat(c) * cw, y: CGFloat(r) * ch),
                            anchor: .topLeading
                        )
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Separators

struct CTSep: View {
    enum Style { case thin, thick }
    var style: Style = .thin

    var body: some View {
        Text(style == .thin ? CTSymbol.thin() : CTSymbol.thick())
            .font(CTFont.regular(10))
            .foregroundColor(Color.CT.noise)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
    }
}

// MARK: - System Message  (> text)

struct CTSystemMessage: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Text(">")
                .font(CTFont.bold(12))
                .foregroundColor(Color.CT.accentDim)
            Text(text)
                .font(CTFont.regular(12))
                .foregroundColor(Color.CT.accentDim)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }
}

// MARK: - Navigation Bar

struct CTNavBar: View {
    let title: String
    var showBack: Bool      = false
    var trailingSymbol: String? = nil
    var backAction: (() -> Void)?     = nil
    var trailingAction: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            if showBack {
                Button(action: { backAction?() }) {
                    Text(CTSymbol.back)
                        .font(CTFont.bold(14))
                        .foregroundColor(Color.CT.accent)
                }
            }
            Text(title)
                .font(CTFont.bold(15))
                .foregroundColor(Color.CT.text)
            Spacer()
            if let sym = trailingSymbol {
                Button(action: { trailingAction?() }) {
                    Text(sym)
                        .font(CTFont.bold(16))
                        .foregroundColor(Color.CT.accent)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .ctBorderBottom()
    }
}

// MARK: - Tab Bar

struct CTTabBar: View {
    @Binding var selected: Int

    private let items: [(symbol: String, label: String)] = [
        (CTSymbol.tabChats,    "chats"),
        (CTSymbol.tabContacts, "contacts"),
        (CTSymbol.tabSettings, "settings"),
    ]

    var body: some View {
        HStack {
            ForEach(items.indices, id: \.self) { i in
                Spacer()
                Button(action: { selected = i }) {
                    Text(items[i].symbol)
                        .font(selected == i ? CTFont.bold(16) : CTFont.regular(16))
                        .foregroundColor(selected == i ? Color.CT.accent : Color.CT.textDim)
                }
                Spacer()
            }
        }
        .padding(.vertical, 12)
        .ctBorderTop()
    }
}

// MARK: - Settings Components

struct CTSettingsSectionHeader: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Text(">")
                .font(CTFont.bold(11))
                .foregroundColor(Color.CT.accentDim)
            Text(title)
                .font(CTFont.bold(11))
                .foregroundColor(Color.CT.accentDim)
        }
        .padding(.horizontal, 12)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }
}

struct CTSettingsRow: View {
    let label: String
    let value: String
    var valueColor: Color = Color.CT.text
    var isAction: Bool      = false
    var isDestructive: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            Text(label)
                .font(CTFont.regular(13))
                .foregroundColor(isDestructive ? Color.CT.danger : Color.CT.textDim)
                .frame(width: 150, alignment: .leading)
            Spacer(minLength: 8)
            Text(value)
                .font(isAction ? CTFont.bold(13) : CTFont.regular(13))
                .foregroundColor(
                    isDestructive ? Color.CT.danger :
                    isAction      ? Color.CT.accent : valueColor
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

// MARK: - View Extensions

extension View {

    /// Wraps view in terminal background: dark fill + ASCII noise.
    func ctBackground() -> some View {
        ZStack {
            Color.CT.bg.ignoresSafeArea()
            CTNoise().ignoresSafeArea()
            self
        }
    }

    /// 0.5pt separator line on the bottom edge of the view's background.
    func ctBorderBottom() -> some View {
        background(
            ZStack(alignment: .bottom) {
                Color.CT.bg
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundColor(Color.CT.noise)
            }
        )
    }

    /// 0.5pt separator line on the top edge of the view's background.
    func ctBorderTop() -> some View {
        background(
            ZStack(alignment: .top) {
                Color.CT.bg
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundColor(Color.CT.noise)
            }
        )
    }

    /// Wraps text content in a terminal-style highlighted block (no border radius).
    /// Outgoing → accent blue background. Incoming → dark background + thin border.
    func ctMessageBlock(outgoing: Bool) -> some View {
        self
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(outgoing ? Color.CT.accent : Color.CT.bgMsg)
            .clipShape(Rectangle())
            .overlay(
                Group {
                    if !outgoing {
                        Rectangle().stroke(Color.CT.noise, lineWidth: 0.5)
                    }
                }
            )
    }
}
