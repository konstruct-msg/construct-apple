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

    // State
    static let pin         = "[pin]"
    static let scan        = "[scan]"
    static let search      = "[srch]"
    static let drafts      = "[dft]"

    // Tab bar
    static let tabChats    = "[msg]"
    static let tabSynaps   = "[syn]"
    static let tabCalls    = "[tel]"
    static let tabContacts = "[syn]"
    static let tabSettings = "[cfg]"

    // Input
    static let mic         = "[mic]"
    static let attach      = "[+]"

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

// MARK: - CTHexAvatar

struct CTHexAvatar: View {
    var initials: String
    var image: Image? = nil
    var size: AvatarSize = .medium
    /// Seed for deterministic color (pass userId or username). Defaults to initials.
    var colorSeed: String? = nil

    enum AvatarSize: CGFloat {
        case small  = 32
        case medium = 40
        case large  = 56
        case xlarge = 80
    }

    private var accentColor: Color {
        Color.hexagonAccent(for: colorSeed ?? initials)
    }

    var body: some View {
        ZStack {
            if let image {
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.rawValue, height: size.rawValue)
                    .clipShape(CTHexShape())
                CTHexShape()
                    .stroke(accentColor, lineWidth: 1)
            } else {
                CTHexShape()
                    .fill(accentColor.opacity(0.18))
                CTHexShape()
                    .stroke(accentColor, lineWidth: 1)
                Text(String(initials.prefix(2)).uppercased())
                    .font(CTFont.bold(size.rawValue * 0.28))
                    .foregroundColor(accentColor)
            }
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
    var trailingColor: Color    = Color.CT.accent
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
            Text(title.uppercased())
                .font(CTFont.bold(13))
                .foregroundColor(Color.CT.text)
                .tracking(4)
            Spacer()
            if let sym = trailingSymbol {
                Button(action: { trailingAction?() }) {
                    Text(sym)
                        .font(CTFont.regular(13))
                        .foregroundColor(trailingColor)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .ctBorderBottom()
    }
}

// MARK: - Tab Bar

struct CTTabItem {
    let symbol: String
    let label: String
}

struct CTTabBar: View {
    @Binding var selected: Int
    var items: [CTTabItem]

    /// Convenience initialiser with default 3-tab layout (chats / synaps / settings).
    init(selected: Binding<Int>, items: [CTTabItem] = CTTabBar.defaultItems) {
        _selected = selected
        self.items = items
    }

    static let defaultItems: [CTTabItem] = [
        CTTabItem(symbol: CTSymbol.tabChats,    label: "MSG"),
        CTTabItem(symbol: CTSymbol.tabSynaps,   label: "SYN"),
        CTTabItem(symbol: CTSymbol.tabSettings, label: "CFG"),
    ]

    var body: some View {
        HStack {
            ForEach(items.indices, id: \.self) { i in
                Spacer()
                Button(action: { selected = i }) {
                    VStack(spacing: 2) {
                        Text(items[i].symbol)
                            .font(selected == i ? CTFont.bold(13) : CTFont.regular(13))
                            .foregroundColor(selected == i ? Color.CT.accent : Color.CT.textDim)
                        Text(selected == i ? "> \(items[i].label)" : items[i].label)
                            .font(selected == i ? CTFont.bold(9) : CTFont.regular(9))
                            .foregroundColor(selected == i ? Color.CT.accent : Color.CT.textDim)
                    }
                }
                Spacer()
            }
        }
        .padding(.vertical, 10)
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
            Text(title.uppercased())
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

// MARK: - Text Field

struct CTTextField: View {
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false
    var alignment: TextAlignment = .leading

    var body: some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .font(CTFont.regular(14))
        .foregroundColor(Color.CT.text)
        .multilineTextAlignment(alignment)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(Color.CT.bgMsg)
        .overlay(Rectangle().stroke(Color.CT.noise, lineWidth: 0.5))
        #if os(macOS)
        .textFieldStyle(.plain)
        #endif
    }
}

// MARK: - Button

struct CTButton: View {
    let label: String
    var isEnabled: Bool    = true
    var isDestructive: Bool = false
    let action: () -> Void

    var fgColor: Color {
        guard isEnabled else { return Color.CT.textDim }
        return isDestructive ? .white : Color.CT.bg
    }

    var bgColor: Color {
        guard isEnabled else { return Color(hex: 0x1C1C1C) }
        return isDestructive ? Color.CT.danger : Color.CT.accent
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(CTFont.bold(13))
                .foregroundColor(fgColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(bgColor)
                .overlay(
                    Rectangle()
                        .stroke(isEnabled ? Color.clear : Color.CT.noise, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
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

    /// Flat 0.5pt noise-coloured border with no padding. Use after setting your own background.
    func ctNoiseBorder() -> some View {
        self
            .clipShape(Rectangle())
            .overlay(Rectangle().stroke(Color.CT.noise, lineWidth: 0.5))
    }
}
