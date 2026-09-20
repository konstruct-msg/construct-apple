//
//  DesktopCommands.swift
//  Construct Desktop
//
//  macOS menu bar commands + keyboard shortcut system.
//
//  Keyboard map (native Mac — decisions/desktop-interaction-is-not-ios D5):
//    ⌘N          — new conversation
//    ⌘⌥N         — add contact
//    ⌘K          — quick-open (focus sidebar search)
//    ⌘F          — find in the current context (chat transcript, else sidebar)
//    ⌘1…⌘9       — jump to Nth chat in sidebar
//    ⌥⌘↓         — select next chat
//    ⌥⌘↑         — select prev chat
//    ⌘[          — close detail (empty state)
//    ⌘,          — open Settings
//    ⌘W          — close front window (macOS standard)
//    ⌘⇧C         — copy id of the open chat
//    ⌘R          — sync pending messages (manual fetch)
//
//  Do not bind a shortcut to a feature that does not exist. ⌘⇧F was "global search"
//  and called the same function as ⌘F.
//

import SwiftUI
import AppKit

// MARK: - Commands group

struct ConstructCommands: Commands {

    let bridge: DesktopCommandBridge

    var body: some Commands {

        // Replace the default "New Window" File menu
        CommandGroup(replacing: .newItem) {
            Button(NSLocalizedString("desktop_new_conversation", comment: "")) {
                bridge.newConversation()
            }
            .keyboardShortcut("n", modifiers: .command)

            Button(NSLocalizedString("find", comment: "")) {
                bridge.find()
            }
            .keyboardShortcut("f", modifiers: .command)

            Divider()

            Button(NSLocalizedString("desktop_sync_messages", comment: "")) {
                bridge.syncMessages()
            }
            .keyboardShortcut("r", modifiers: .command)
        }

        // Navigate menu
        CommandMenu(LocalizedStringKey("desktop_menu_navigate")) {
            Button(NSLocalizedString("desktop_next_chat", comment: "")) {
                bridge.selectNextChat()
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])

            Button(NSLocalizedString("desktop_previous_chat", comment: "")) {
                bridge.selectPrevChat()
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])

            Divider()

            Button(NSLocalizedString("people", comment: "")) {
                bridge.openPeople()
            }

            Button(NSLocalizedString("quick_open", comment: "")) {
                bridge.focusSearch()
            }
            .keyboardShortcut("k", modifiers: .command)

            Divider()

            ForEach(1...9, id: \.self) { n in
                Button(String(format: NSLocalizedString("desktop_jump_to_chat_fmt", comment: ""), n)) {
                    bridge.jumpToChat(index: n - 1)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
            }

            Divider()

            Button(NSLocalizedString("desktop_close_chat", comment: "")) {
                bridge.back()
            }
            .keyboardShortcut("[", modifiers: .command)
        }

        // Construct menu (app-specific actions)
        CommandMenu("Construct") {
            Button(NSLocalizedString("add_contact_menu", comment: "")) {
                bridge.addContact()
            }
            .keyboardShortcut("n", modifiers: [.command, .option])

            Divider()

            Button(NSLocalizedString("copy_id", comment: "")) {
                bridge.copyNodeId()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])

            Button(NSLocalizedString("desktop_show_security", comment: "")) {
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
    var onFind:            (() -> Void)?
    var onOpenPeople:      (() -> Void)?
    var onSelectNext:      (() -> Void)?
    var onSelectPrev:      (() -> Void)?
    var onJumpToIndex:     ((Int) -> Void)?
    var onBack:            (() -> Void)?
    var onCopyNodeId:      (() -> Void)?
    var onShowSecurity:    (() -> Void)?
    var onSyncMessages:    (() -> Void)?

    func newConversation() { onNewConversation?() }
    func addContact()      { onAddContact?() }
    func focusSearch()     { onFocusSearch?() }
    func find()            { onFind?() }
    func openPeople()      { onOpenPeople?() }
    func selectNextChat()  { onSelectNext?() }
    func selectPrevChat()  { onSelectPrev?() }
    func jumpToChat(index: Int) { onJumpToIndex?(index) }
    func back()            { onBack?() }
    func copyNodeId()      { onCopyNodeId?() }
    func showSecurity()    { onShowSecurity?() }
    func syncMessages()    { onSyncMessages?() }
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
