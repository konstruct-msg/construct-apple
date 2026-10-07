//
//  PlatformNavBar.swift
//  Construct Messenger
//
//  The toolbar placements that exist on one platform and not the other.
//

import SwiftUI

extension View {

    /// Hide the system navigation bar so the screen can draw its own `CTNavBar`.
    ///
    /// Retiring with `CTNavBar` — no new call site (`decisions/navigation-bars-are-the-systems.md`).
    ///
    /// `ToolbarPlacement.navigationBar` is unavailable on macOS, and every pushed settings screen
    /// in this app uses it — without hiding the system bar, the screen shows two back buttons.
    /// macOS has no such bar to hide, so there the correct behaviour is to do nothing.
    ///
    /// A shim rather than `#if os(iOS)` at each of the seven call sites: the guard is the same
    /// every time, and seven copies of it is seven places for the next platform to be forgotten.
    @ViewBuilder
    func hideSystemNavBar() -> some View {
        #if os(iOS)
        self.toolbar(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }

    /// Paint the navigation bar, on the platform that has one.
    ///
    /// Used by the one screen that presents a sheet with a system bar it wants dark. On macOS the
    /// window chrome is the host's, not ours to colour.
    @ViewBuilder
    func navBarChrome(_ color: Color) -> some View {
        #if os(iOS)
        self
            .toolbarBackground(color, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        #else
        self
        #endif
    }

    /// A sheet's own navigation: a `NavigationStack` and a close item, so the screen inside
    /// declares only its title and actions and reads the same pushed or presented.
    /// `decisions/navigation-bars-are-the-systems.md`.
    func sheetNavigation() -> some View {
        SheetNavigation(content: self)
    }

    /// `navigationBarTitleDisplayMode(.inline)`, which does not exist on macOS.
    @ViewBuilder
    func inlineNavTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

private struct SheetNavigation<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let content: Content

    var body: some View {
        NavigationStack {
            content.toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CloseButton { dismiss() }
                }
            }
        }
    }
}

/// The platform's close: the system's own button where it has one, else a symbol with a title.
struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            Button(role: .close, action: action)
        } else {
            Button(action: action) {
                Label(NSLocalizedString("close", comment: ""), systemImage: "xmark")
            }
        }
    }
}
