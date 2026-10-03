//
//  DesktopListChrome.swift
//  Construct Desktop
//
//  Selection chrome for the sidebar `List` — the system highlight is replaced by CT.
//

import SwiftUI
import AppKit

/// Selection chrome drawn **behind** the row. The system `List(selection:)` highlight
/// paints an opaque accent over the cell and recolors the hexagon; this view is the
/// replacement once that highlight is turned off (`DesktopListSelectionChrome`).
struct DesktopSelectedRowChrome: View {
    let isActive: Bool

    private static let borderWidth: CGFloat = 1
    private static let fillOpacity: Double = 0.12
    private static let strokeOpacity: Double = 0.45

    var body: some View {
        ZStack {
            Color.CT.bg
            if isActive {
                CTShape.card()
                    .fill(Color.CT.accent.opacity(Self.fillOpacity))
                    .overlay(
                        CTShape.card()
                            .strokeBorder(
                                Color.CT.accent.opacity(Self.strokeOpacity),
                                lineWidth: Self.borderWidth
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
