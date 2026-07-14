//
//  LazyChatViewModel.swift
//  Construct Messenger
//
//  Cheap holder so ChatView/DesktopChatView can put something in @State without
//  constructing ChatViewModel (FRC + coordinators) on every SwiftUI re-init.
//
//  Root cause (see construct-docs sessions/2026-05-16-session-recovery-fixes.md):
//  View.init runs on parent re-render; `State(wrappedValue: ChatViewModel(...))`
//  allocates a real VM that is immediately discarded → deinit spam + wasted work.
//

import CoreData
import Foundation

/// Owns a `ChatViewModel` created on first access only.
/// Safe to allocate in `View.init` — discarded holders never materialize the VM.
@MainActor
final class LazyChatViewModel {
    private let make: () -> ChatViewModel
    private var stored: ChatViewModel?

    init(_ make: @escaping () -> ChatViewModel) {
        self.make = make
    }

    /// Materializes the ViewModel once; subsequent calls return the same instance.
    var value: ChatViewModel {
        if let stored { return stored }
        let vm = make()
        stored = vm
        return vm
    }
}
