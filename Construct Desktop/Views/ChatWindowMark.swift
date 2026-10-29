//
//  ChatWindowMark.swift
//  Construct Desktop
//
//  Marks the window it sits in as the one that shows chats (`MacChatWindows`), so a banner for
//  the open chat is not swallowed while only the call or Studio window is in front.
//

import AppKit
import SwiftUI

struct ChatWindowMark: NSViewRepresentable {
    func makeNSView(context: Context) -> MarkView { MarkView() }
    func updateNSView(_ nsView: MarkView, context: Context) {}

    final class MarkView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { MacChatWindows.add(window) }
        }
    }
}
