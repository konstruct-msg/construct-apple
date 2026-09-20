//
//  DesktopTheme.swift
//  Construct Desktop
//
//  Compatibility shim — all tokens now delegate to the shared CT design system.
//  New code should use Color.CT.* and CTFont directly.
//

import SwiftUI
import AppKit

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
    static let activeBorderWidth: CGFloat = 1
    static let activeFillOpacity: Double = 0.12
    static let activeStrokeOpacity: Double = 0.45
    static let activeBorderColor   = Color.CT.accent

    // MARK: - Typography (→ CTFont / JetBrains Mono)
    static func monoFont(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch weight {
        case .bold, .heavy, .black:        return CTFont.ui(size, weight: .bold)
        case .medium, .semibold:           return CTFont.ui(size, weight: .medium)
        default:                           return CTFont.ui(size)
        }
    }
}

/// Selection chrome drawn **behind** the row. The system `List(selection:)` highlight
/// paints an opaque accent over the cell and recolors the hexagon; this view is the
/// replacement once that highlight is turned off (`DesktopListSelectionChrome`).
struct DesktopSelectedRowChrome: View {
    let isActive: Bool

    var body: some View {
        ZStack {
            Color.CT.bg
            if isActive {
                CTShape.card()
                    .fill(Color.CT.accent.opacity(DesktopTheme.activeFillOpacity))
                    .overlay(
                        CTShape.card()
                            .strokeBorder(
                                Color.CT.accent.opacity(DesktopTheme.activeStrokeOpacity),
                                lineWidth: DesktopTheme.activeBorderWidth
                            )
                    )
                    .padding(.horizontal, CTLayout.inlinePad / 2)
                    .padding(.vertical, 2)
            }
        }
    }
}

/// Walks up to the enclosing `NSTableView` and drops its selection highlight.
/// SwiftUI `List` on macOS still uses that overlay, and `listRowBackground` sits
/// underneath it — so without this the system blue wins and tints the avatar.
private struct DesktopListSelectionChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        SelectionChromeHost()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class SelectionChromeHost: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        private func apply() {
            var view: NSView? = self
            while let current = view {
                if let table = current as? NSTableView {
                    table.selectionHighlightStyle = .none
                    return
                }
                view = current.superview
            }
        }
    }
}

extension View {
    func desktopActiveRow(_ isActive: Bool) -> some View {
        listRowBackground(DesktopSelectedRowChrome(isActive: isActive))
    }

    /// Call once on the `List`, not per row.
    func desktopSuppressSystemListSelection() -> some View {
        background {
            DesktopListSelectionChrome()
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
