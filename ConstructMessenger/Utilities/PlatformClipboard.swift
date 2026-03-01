//
//  PlatformClipboard.swift
//  Construct Messenger
//
//  Platform-agnostic clipboard abstraction.
//  Replaces direct UIPasteboard / NSPasteboard usage so the same
//  call site compiles on iOS, macOS Catalyst, and native macOS.
//

import Foundation

enum PlatformClipboard {
    /// Copy a string to the system clipboard.
    static func copy(_ string: String) {
        #if os(iOS)
        UIPasteboard.general.string = string
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }

    /// Paste the current string from the system clipboard, if any.
    static func paste() -> String? {
        #if os(iOS)
        return UIPasteboard.general.string
        #elseif os(macOS)
        return NSPasteboard.general.string(forType: .string)
        #else
        return nil
        #endif
    }
}
