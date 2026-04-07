//
//  DesktopCommands.swift
//  Construct Desktop
//
//  macOS menu bar commands + keyboard shortcut system.
//  Terminal/TUI aesthetic: vim-inspired navigation, no mouse required.
//
//  Keyboard map:
//    ⌘N          — new conversation
//    ⌘⌥N         — add contact / scan QR
//    ⌘K          — quick-jump (focus sidebar search)
//    ⌘F          — find / search chats
//    ⌘1…⌘9       — jump to Nth chat in sidebar
//    ⌘J / ⌘↓     — select next chat
//    ⌘K / ⌘↑     — select prev chat  (⌘K only when search not focused)
//    ⌘[          — back / close detail
//    ⌘⇧F         — global message search
//    ⌘,          — open Settings
//    ⌘W          — close front window (macOS standard)
//    ⌘⇧C         — copy node ID of active chat
//

import SwiftUI
import AppKit

// MARK: - Commands group

struct ConstructCommands: Commands {

    let bridge: DesktopCommandBridge

    var body: some Commands {

        // Replace the default "New Window" File menu
        CommandGroup(replacing: .newItem) {
            Button("New Conversation") {
                bridge.newConversation()
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Add Contact…") {
                bridge.addContact()
            }
            .keyboardShortcut("n", modifiers: [.command, .option])

            Divider()

            Button("Find Chat") {
                bridge.focusSearch()
            }
            .keyboardShortcut("f", modifiers: .command)

            Button("Global Search") {
                bridge.globalSearch()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
        }

        // Navigate menu (TUI-style)
        CommandMenu("Navigate") {
            Button("Next Chat") {
                bridge.selectNextChat()
            }
            .keyboardShortcut("j", modifiers: .command)

            Button("Previous Chat") {
                bridge.selectPrevChat()
            }
            .keyboardShortcut("k", modifiers: .command)

            Divider()

            Button("Quick Open") {
                bridge.focusSearch()
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])

            Divider()

            ForEach(1...9, id: \.self) { n in
                Button("Jump to Chat \(n)") {
                    bridge.jumpToChat(index: n - 1)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
            }

            Divider()

            Button("Back") {
                bridge.back()
            }
            .keyboardShortcut("[", modifiers: .command)
        }

        // Construct menu (app-specific actions)
        CommandMenu("Construct") {
            Button("Copy Node ID") {
                bridge.copyNodeId()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])

            Button("Show Security Info") {
                bridge.showSecurity()
            }
        }
    }
}

// MARK: - Command bridge (ObservableObject — bridges SwiftUI commands → @MainActor ViewModels)

/// Lightweight relay: Commands closures are called on main thread but live
/// outside the SwiftUI environment, so they can't access @Environment VMs directly.
/// DesktopCommandBridge is owned by the App struct and passed both to Commands
/// and to DesktopRootView via @Environment.
@Observable
final class DesktopCommandBridge {

    // Callbacks set by DesktopRootView once it has access to the ViewModels
    var onNewConversation: (() -> Void)?
    var onAddContact:      (() -> Void)?
    var onFocusSearch:     (() -> Void)?
    var onGlobalSearch:    (() -> Void)?
    var onSelectNext:      (() -> Void)?
    var onSelectPrev:      (() -> Void)?
    var onJumpToIndex:     ((Int) -> Void)?
    var onBack:            (() -> Void)?
    var onCopyNodeId:      (() -> Void)?
    var onShowSecurity:    (() -> Void)?

    func newConversation() { onNewConversation?() }
    func addContact()      { onAddContact?() }
    func focusSearch()     { onFocusSearch?() }
    func globalSearch()    { onGlobalSearch?() }
    func selectNextChat()  { onSelectNext?() }
    func selectPrevChat()  { onSelectPrev?() }
    func jumpToChat(index: Int) { onJumpToIndex?(index) }
    func back()            { onBack?() }
    func copyNodeId()      { onCopyNodeId?() }
    func showSecurity()    { onShowSecurity?() }
}

// MARK: - Environment key for bridge

private struct DesktopCommandBridgeKey: EnvironmentKey {
    static let defaultValue: DesktopCommandBridge = DesktopCommandBridge()
}

extension EnvironmentValues {
    var commandBridge: DesktopCommandBridge {
        get { self[DesktopCommandBridgeKey.self] }
        set { self[DesktopCommandBridgeKey.self] = newValue }
    }
}
