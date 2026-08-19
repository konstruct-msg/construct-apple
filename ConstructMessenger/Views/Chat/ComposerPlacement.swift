//
//  ComposerPlacement.swift
//  Construct Messenger
//
//  Where the composer sits: a safe-area inset, or an overlay above content that already left room
//  for it. PR-3; the `false` branch and this whole file go with the flag in PR-4.
//

import SwiftUI

/// The second of the two roots the migration removes.
///
/// `.safeAreaInset(edge: .bottom)` makes the composer's height a property of the *scroll view*.
/// Every time the composer grows — reply bar, media strip, a second line of text — the system
/// rewrites the scroll view's inset underneath a `.defaultScrollAnchor(.bottom)`, and the offset is
/// re-derived while the inset is still animating. That is the window the old code spent four delay
/// series chasing.
///
/// As an overlay the composer stops being layout input at all. The room for it is `bottomContentPad`
/// inside the scroll content, which this view's parent owns and writes once per measured change, so
/// the tail sits above the glass because the content says so — not because something scrolled it
/// there afterwards.
///
/// The composer keeps reporting its height either way. On the legacy path that number is only a
/// trigger; on this one it is the pad.
struct ComposerPlacement<Composer: View>: ViewModifier {

    let usesOverlay: Bool
    @ViewBuilder let composer: () -> Composer

    func body(content: Content) -> some View {
        if usesOverlay {
            content.overlay(alignment: .bottom) { composer() }
        } else {
            content.safeAreaInset(edge: .bottom, spacing: 0) { composer() }
        }
    }
}
