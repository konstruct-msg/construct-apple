//
//  DesktopTheme.swift
//  Construct Desktop
//
//  The theme chosen in Settings, for every window. Each scene's window takes its appearance from
//  its own root view, so a scene without this follows the system: a light call window over a dark
//  main window (2026-10-28).
//

import SwiftUI

private struct DesktopThemed: ViewModifier {
    @AppStorage("appTheme") private var appTheme: AppTheme = .dark

    func body(content: Content) -> some View {
        content.preferredColorScheme(appTheme.colorScheme)
    }
}

extension View {
    /// Every scene's root view wears this.
    func desktopTheme() -> some View { modifier(DesktopThemed()) }
}
