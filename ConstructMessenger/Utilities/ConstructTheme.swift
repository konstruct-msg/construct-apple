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
//

import SwiftUI

// MARK: - Color Palette

extension Color {
    /// Terminal design palette. All new CT* views use these exclusively.
    /// Colors are dynamic: dark variant is the classic terminal aesthetic,
    /// light variant uses a very light gray base with dark ink.
    struct CT {
        // MARK: Backgrounds
        /// Main background. Dark: #090909 / Light: #F2F2F2
        static let bg         = Color(dark: 0x090909, light: 0xF2F2F2)
        /// Message bubble background (incoming). Dark: #333333 / Light: #E2E2E2
        static let bgMsg      = Color(dark: 0x202020, light: 0xE2E2E2)
        /// Outgoing message background. Dark: #111111 / Light: #CECECE
        static let outMsgBg   = Color(dark: 0x111111, light: 0xE9E9E9)

        // MARK: Accent (brand blue — unchanged across themes)
        /// Primary accent: #1A3FFF
        static let accent     = Color(hex: 0x0062FF)
        /// Secondary accent: #4A6AFF
        static let accentDim  = Color(hex: 0x1E68DF)

        // MARK: Text
        /// Primary text. Dark: #E8E8E8 / Light: #111111
        static let text       = Color(dark: 0xE8E8E8, light: 0x111111)
        /// Timestamps, metadata, inactive.
        static let textDim    = Color(dark: 0x818181, light: 0x333333)
        /// Text/icons inside outgoing bubbles. Dark: #FFFFFF (on #111111) /
        /// Light: #111111 (on #E9E9E9). Adaptive — never hardcode `.white` here,
        /// or it becomes unreadable on the light outgoing background.
        static let outMsgText = Color(dark: 0xFFFFFF, light: 0x111111)

        // MARK: Structure
        /// ASCII noise chars, dividers. Dark: #1E1E1E / Light: #C8C8C8
        static let noise      = Color(dark: 0x1E1E1E, light: 0xC8C8C8)
        /// Destructive actions: #DC3C3C (unchanged)
        static let danger     = Color(hex: 0xDC3C3C)
    }
}

// MARK: - Dynamic color helper (dark/light)

private extension Color {
    /// Creates a `Color` from a 24-bit RGB hex value.
    init(rgb hex: UInt32) {
        self.init(
            red:   Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >>  8) & 0xff) / 255,
            blue:  Double( hex        & 0xff) / 255
        )
    }

    /// Creates a `Color` that adapts to the system's user interface style.
    /// - Parameters:
    ///   - dark:  24-bit RGB hex used in dark mode (e.g. `0x090909`)
    ///   - light: 24-bit RGB hex used in light mode (e.g. `0xF2F2F2`)
    init(dark: UInt32, light: UInt32) {
        #if os(iOS)
        self.init(uiColor: UIColor(dynamicProvider: { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(rgb: dark)
                : UIColor(rgb: light)
        }))
        #else
        // macOS: honour the effective appearance of the current NSApp
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(rgb: dark)
                : NSColor(rgb: light)
        })
        #endif
    }
}

#if os(iOS)
private extension UIColor {
    convenience init(rgb hex: UInt32) {
        self.init(
            red:   CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >>  8) & 0xff) / 255,
            blue:  CGFloat( hex        & 0xff) / 255,
            alpha: 1
        )
    }
}
#else
private extension NSColor {
    convenience init(rgb hex: UInt32) {
        self.init(
            red:   CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >>  8) & 0xff) / 255,
            blue:  CGFloat( hex        & 0xff) / 255,
            alpha: 1
        )
    }
}
#endif

// MARK: - Typography

/// Thin wrapper around ConstructFont so CT* views need no direct dependency on UIConstants.
enum CTFont {
    static func regular(_ size: CGFloat) -> Font { ConstructFont.mono(size, weight: .regular) }
    static func medium(_ size: CGFloat)  -> Font { ConstructFont.mono(size, weight: .medium)  }
    static func bold(_ size: CGFloat)    -> Font { ConstructFont.mono(size, weight: .bold)    }
}

// MARK: - Layout Constants

/// Canonical sizing tokens for nav bars, action icons, and content rows.
///
/// All icon sizes are derived from `CTFont.bold(13)` line height (~16 pt) so that
/// a nav bar containing only an SF Symbol is the same height as one containing text.
enum CTLayout {
    /// Horizontal edge inset shared by nav bars, section headers, and content rows.
    static let edgePad: CGFloat = 12

    /// Vertical padding for navigation bar rows.
    static let navVPad: CGFloat = 11

    /// Fixed height for every navigation bar. Using frame(height:) instead of
    /// padding ensures the title sits at the same absolute vertical position
    /// regardless of whether the bar has a back button, trailing icon, or text only.
    static let navBarHeight: CGFloat = 44

    /// SF Symbol size for standard nav-bar action buttons (QR scan, search, dismiss).
    static let navIconSize: CGFloat = 20

    /// Slightly larger icon for elevated primary-action buttons (e.g., phone call in chat).
    static let navIconSizeLg: CGFloat = 22

    /// Large icon for full-screen call UI (accept / decline / mute buttons).
    static let callIconSize: CGFloat = 24
}

// MARK: - Cross-platform helpers

extension Color {
    /// System background color — `systemBackground` on iOS, `windowBackgroundColor` on macOS.
    static var platformBackground: Color {
        #if os(iOS)
        Color(.systemBackground)
        #else
        Color(.windowBackgroundColor)
        #endif
    }
}

// MARK: - Symbol Table

/// All UI symbols as named constants. Never hardcode "[←]" inline.
enum CTSymbol {

    static let star8 = "✷"

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
    static let refresh  = "[↺]"
    static let retry    = "[↺]"
    static let upload   = "[↑]"
    static let callOut  = "[↗]"

    // Status
    static let ok          = "[✓]"
    static let read        = "[↵]"
    static let delivered   = "[✓✓]"
    static let error       = "[!]"
    static let online      = "[[ONLINE]]"
    static let cursor      = "_"
    static let loading     = "[···]"
    static let empty       = "[ — ]"

    // State
    static let pin         = "[pin]"
    static let scan        = "[scan]"
    static let search      = "[srch]"
    static let drafts      = "[dft]"
    static let ttl         = "[ttl]"
    static let setup       = "[setup →]"

    // Security / Settings row icons
    static let biometric   = "[bio]"
    static let key         = "[key]"
    static let lock        = "[lock]"
    static let log         = "[log]"
    static let disk        = "[disk]"
    static let image       = "[img]"

    // Calls
    static let callEnd     = "[end]"
    static let callAnswer  = "[ans]"

    // Devices / Platform
    static let deviceGeneric  = "[dev]"
    static let deviceIOS      = "[iOS]"
    static let deviceMac      = "[mac]"
    static let deviceAndroid  = "[drd]"

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

// MARK: - CTRowIcon

/// A fixed-width icon column for use in list rows (settings, devices, etc).
/// Handles the lineLimit + fixedSize + frame pattern that prevents CT bracket
/// symbols from wrapping across lines in narrow containers.
///
/// Usage:
///   CTRowIcon(CTSymbol.biometric)
///   CTRowIcon(CTSymbol.key, color: .CT.accent)
///   CTRowIcon(sf: "moon.fill", color: .CT.accent)   // SF Symbol variant
struct CTRowIcon: View {
    private enum Content {
        case ascii(String)
        case sfSymbol(String)
    }

    private let content: Content
    var color: Color  = Color.CT.textDim
    var size: CGFloat = 14

    // ASCII / CTSymbol init
    init(_ symbol: String, color: Color = Color.CT.textDim, size: CGFloat = 14) {
        self.content = .ascii(symbol)
        self.color   = color
        self.size    = size
    }

    // SF Symbol init
    init(sf symbolName: String, color: Color = Color.CT.textDim, size: CGFloat = 16) {
        self.content = .sfSymbol(symbolName)
        self.color   = color
        self.size    = size
    }

    var body: some View {
        Group {
            switch content {
            case .ascii(let symbol):
                Text(symbol)
                    .font(CTFont.bold(size))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .fixedSize()
            case .sfSymbol(let name):
                Image(systemName: name)
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(color)
            }
        }
        .frame(minWidth: 36, alignment: .leading)
    }
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
                    .clipShape(Circle())
                Circle()
                    .stroke(accentColor, lineWidth: 1)
            } else {
                Circle()
                    .fill(accentColor.opacity(0.18))
                Circle()
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

// MARK: - Mode Selector (tri-state segmented control)

/// A CT-styled segmented control for selecting between modes.
/// No rounded corners, accent color on selected segment, ASCII aesthetic.
struct CTModeSelector<T: Hashable>: View {
    @Binding var selection: T
    let options: [T]
    let labels: [T: String]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let isSelected = selection == option
                Button {
                    selection = option
                } label: {
                    Text(labels[option] ?? "")
                        .font(CTFont.regular(12))
                        .foregroundColor(isSelected ? Color.CT.bg : Color.CT.textDim)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(isSelected ? Color.CT.accent : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .overlay(Rectangle().stroke(Color.CT.accent.opacity(0.4), lineWidth: 0.5))
        .frame(width: 180)
    }
}

// MARK: - Separator

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

// MARK: - Section Group

/// Rounded card container for settings sections that use the flat CTSettingsRow pattern.
/// Wraps rows in a subtle elevated background with cornerRadius 8.
/// Usage: wrap the rows of one section (not the CTSettingsSectionHeader) in CTSectionGroup { ... }
/// Remove CTSep(style: .thick) between sections — CTSettingsSectionHeader's .padding(.top, 16) provides the gap.
struct CTSectionGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(Color.CT.outMsgBg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.CT.noise, lineWidth: 0.5))
        .padding(.horizontal, 12)
    }
}

// MARK: - System Message  (> text)

// MARK: - Search Bar

/// Unified terminal-style search bar. Used in ChatsListView and SynapsView.
/// Renders as a full-width row with bottom border (same visual weight as nav bars).
///
/// Usage:
///   CTSearchBar(text: $searchQuery)
///   CTSearchBar(text: $searchText, placeholder: LocalizedStringKey("search_prompt"))
struct CTSearchBar: View {
    @Binding var text: String
    var placeholder: LocalizedStringKey = "search_prompt"
    var focused: FocusState<Bool>.Binding? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(Color.CT.textDim)

            TextField("", text: $text,
                      prompt: Text(placeholder)
                        .font(CTFont.regular(13))
                        .foregroundColor(Color.CT.textDim))
                .font(CTFont.regular(13))
                .foregroundColor(Color.CT.text)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                #endif
                .tint(Color.CT.accent)

            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(Color.CT.textDim)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.CT.bgMsg)
        .ctBorderBottom()
    }
}


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
    /// On macOS sheet/modal contexts pass true — renders xmark.circle (close) instead of chevron (back).
    var isModal: Bool       = false
    var trailingSymbol: String? = nil
    var trailingSystemImage: String? = nil
    var trailingSecondarySystemImage: String? = nil
    var trailingColor: Color    = Color.CT.accent
    /// Colour for the secondary trailing icon (typically a cancel/dismiss
    /// next to a primary confirm). Defaults to dim so confirm vs cancel are
    /// visually distinct — same colour for both reads as "two identical
    /// buttons" and confuses the user (FaceTime-style: primary = accent,
    /// secondary = muted).
    var trailingSecondaryColor: Color = Color.CT.textDim
    var backAction: (() -> Void)?     = nil
    var trailingAction: (() -> Void)? = nil
    var trailingSecondaryAction: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if showBack {
                Button(action: { backAction?() }) {
                    #if os(macOS)
                    Image(systemName: isModal ? "xmark.circle" : "chevron.backward.circle")
                        .font(.system(size: 18))
                        .foregroundColor(Color.CT.accent)
                    #else
                    Image(systemName: "chevron.backward.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(Color.CT.accent)
                    #endif
                }
                .buttonStyle(.plain)
            }
            Text(title.uppercased())
                .font(CTFont.bold(14))
                .foregroundColor(Color.CT.text)
                .tracking(4)
            Spacer()
            if trailingSystemImage != nil || trailingSecondarySystemImage != nil {
                HStack(spacing: 10) {
                    if let secondaryImageName = trailingSecondarySystemImage {
                        Button(action: { trailingSecondaryAction?() }) {
                            Image(systemName: secondaryImageName)
                                .font(.system(size: 18))
                                .foregroundColor(trailingSecondaryColor)
                        }
                        .buttonStyle(.plain)
                    }
                    if let imageName = trailingSystemImage {
                        Button(action: { trailingAction?() }) {
                            Image(systemName: imageName)
                                .font(.system(size: 18))
                                .foregroundColor(trailingColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if let sym = trailingSymbol {
                Button(action: { trailingAction?() }) {
                    Text(sym)
                        .font(CTFont.regular(13))
                        .foregroundColor(trailingColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, CTLayout.edgePad)
        .frame(height: CTLayout.navBarHeight)
        .ctBorderBottom()
    }
}

// MARK: - Tab Bar

struct CTTabItem {
    let symbol: String
    var sfName: String
}

struct CTTabBar: View {
    @Binding var selected: Int
    var items: [CTTabItem]

    /// Convenience initialiser with default 3-tab layout (chats / synaps / settings).
    init(selected: Binding<Int>, items: [CTTabItem] = CTTabBar.defaultItems) {
        _selected = selected
        self.items = items
    }

    static var defaultItems: [CTTabItem] {
        [
            CTTabItem(symbol: CTSymbol.tabChats, sfName: "message"),
            CTTabItem(symbol: CTSymbol.tabSynaps, sfName: "circle.grid.cross"),
            CTTabItem(symbol: CTSymbol.tabSettings, sfName: "gearshape"),
        ]
    }

    var body: some View {
        HStack {
            ForEach(items.indices, id: \.self) { i in
                Spacer()
                Button(action: { selected = i }) {
                    let sf = items[i].sfName
                    Image(systemName: selected == i && !sf.hasSuffix(".fill") ? sf + ".fill" : sf)
                        .font(.system(size: 20))
                        .foregroundColor(selected == i ? Color.CT.accent : Color.CT.textDim)
                    
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
    var color: Color = Color.CT.accentDim

    var body: some View {
        HStack(spacing: 6) {
            Text(">")
                .font(CTFont.bold(11))
                .foregroundColor(color)
            Text(title.uppercased())
                .font(CTFont.bold(11))
                .foregroundColor(color)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }
}

struct CTSettingsRow: View {
    let label: String
    let value: String
    var icon: String?       = nil
    var labelColor: Color   = Color.CT.text
    var valueColor: Color   = Color.CT.text
    var isAction: Bool      = false
    var isDestructive: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(isDestructive ? Color.CT.danger : labelColor)
                    .frame(width: 28, alignment: .center)
                    .padding(.trailing, 4)
            }
            Text(label)
                .font(CTFont.regular(13))
                .foregroundColor(isDestructive ? Color.CT.danger : labelColor)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
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
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.CT.noise, lineWidth: 0.5))
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
        guard isEnabled else { return Color(dark: 0x1C1C1C, light: 0xD8D8D8) }
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
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isEnabled ? Color.clear : Color.CT.noise, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

// MARK: - CT Background View (adapts noise opacity to theme)

private struct _CTBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color.CT.bg.ignoresSafeArea()
            // Lower noise opacity in light mode so characters remain barely visible.
            CTNoise(opacity: colorScheme == .dark ? 0.10 : 0.06).ignoresSafeArea()
        }
    }
}

// MARK: - View Extensions

extension View {

    /// Wraps view in terminal background: theme-appropriate fill + ASCII noise.
    func ctBackground() -> some View {
        self.background(_CTBackground())
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
