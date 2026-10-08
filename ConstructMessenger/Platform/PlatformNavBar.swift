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

    /// A screen's title on the system bar, inline. `shown: false` where the screen is embedded in
    /// a host that names it (the Desktop settings pane).
    @ViewBuilder
    func screenTitle(_ title: String, shown: Bool = true) -> some View {
        if shown {
            self.navigationTitle(title).inlineNavTitle()
        } else {
            self
        }
    }

    /// The connection state under a tab root's title — "Connecting…", "Disconnected" — and nothing
    /// while connected: the state a person needs to know about, said in words where the title is,
    /// instead of an unlabelled dot beside it. iOS/macOS 26 (`navigationSubtitle`); before that
    /// the title stands alone.
    func connectionSubtitle() -> some View {
        modifier(ConnectionSubtitle())
    }

    /// A sheet's own navigation: a `NavigationStack` and a close item, so the screen inside
    /// declares only its title and actions and reads the same pushed or presented.
    /// `decisions/navigation-bars-are-the-systems.md`.
    /// `closes: false` where the screen has its own close — one that does more than dismiss.
    func sheetNavigation(closes: Bool = true) -> some View {
        SheetNavigation(content: self, closes: closes)
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
    let closes: Bool

    var body: some View {
        NavigationStack {
            content.toolbar {
                if closes {
                    ToolbarItem(placement: .cancellationAction) {
                        CloseButton { dismiss() }
                    }
                }
            }
        }
    }
}

/// The platform's close: the system's own button where it has one, else a symbol with a title.
struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        Group {
            if #available(iOS 26.0, macOS 26.0, *) {
                Button(role: .close, action: action)
            } else {
                Button(action: action) {
                    Label(NSLocalizedString("close", comment: ""), systemImage: "xmark")
                }
            }
        }
        .barItem()
    }
}

/// A confirming bar action (Save, Done): the system's prominent confirm where it has one — the
/// one item in a bar that takes the accent — else a plain button with the title.
struct ConfirmButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            Button(title, role: .confirm, action: action)
        } else {
            Button(title, action: action)
        }
    }
}

extension View {
    /// A bar item in the label colour. iOS 26 draws the system back that way and the tab view
    /// tints everything under it with the accent, so without this a close or an edit beside the
    /// back would be the only blue in the bar. A confirming action is `ConfirmButton` instead.
    func barItem() -> some View {
        tint(Color.CT.text)
    }
}

private struct ConnectionSubtitle: ViewModifier {
    var connection = ConnectionStatusManager.shared
    @State private var hasConnectedOnce = false

    /// Mirrors `ConnectionStatusIndicator`: before the first connect a drop is still "connecting";
    /// a paused stream is the app in the background, where no one reads the bar.
    private var text: String {
        if connection.isStreamPaused { return "" }
        switch connection.connectionStatus {
        case .connected: return ""
        case .connecting, .unknown: return NSLocalizedString("status_connecting", comment: "")
        case .disconnected:
            return NSLocalizedString(hasConnectedOnce ? "disconnected" : "status_connecting", comment: "")
        }
    }

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 26.0, macOS 26.0, *) {
                content.navigationSubtitle(text)
            } else {
                content
            }
        }
        .onAppear { if connection.connectionStatus == .connected { hasConnectedOnce = true } }
        .onChange(of: connection.connectionStatus) { _, status in
            if status == .connected { hasConnectedOnce = true }
        }
    }
}
