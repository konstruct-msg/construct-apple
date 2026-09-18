//
//  ChatListNavigation.swift
//  Construct Desktop
//
//  Where ⌥⌘↓, ⌥⌘↑ and ⌘1…9 land.
//
//  Split out of the list view because the arithmetic has more edge cases than it looks: nothing
//  open yet, the ends of the list, an index past the end, a search box that has hidden the chat
//  currently open. All of them are decisions about behaviour, and none of them are testable while
//  they live inside a view that needs Core Data to exist.
//

import Foundation

enum ChatListNavigation {

    /// The chat `step` rows away from `current`, in the order the user sees.
    ///
    /// `nil` means "stay where you are". With nothing open, either direction opens an end of the
    /// list rather than doing nothing — pressing "next chat" on an empty detail pane should show a
    /// chat. The ends do not wrap: on a long list a silent jump from last to first reads as a
    /// misfire, and ⌘1 already means "go to the top".
    ///
    /// A `current` that is not in `visible` is the search case — the open chat has been filtered
    /// out. Treated as "nothing open", so the keys still move within what is on screen.
    static func step(from current: String?, by step: Int, in visible: [String]) -> String? {
        guard !visible.isEmpty else { return nil }

        guard let current, let index = visible.firstIndex(of: current) else {
            return step > 0 ? visible.first : visible.last
        }

        let target = index + step
        guard visible.indices.contains(target) else { return nil }
        return visible[target]
    }

    /// ⌘1…⌘9 — the nth chat as displayed, or `nil` when the list is shorter than that.
    static func jump(to index: Int, in visible: [String]) -> String? {
        visible.indices.contains(index) ? visible[index] : nil
    }
}
