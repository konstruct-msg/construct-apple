//
//  PlatformClipboard.swift
//  Construct Messenger
//
//  Platform-agnostic clipboard abstraction.
//  Replaces direct UIPasteboard / NSPasteboard usage so the same
//  call site compiles on iOS, macOS Catalyst, and native macOS.
//

import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum PlatformClipboard {
    /// Copy a string to the system clipboard.
    static func copy(_ string: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = string
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }

    /// Paste the current string from the system clipboard, if any.
    static func paste() -> String? {
        #if canImport(UIKit)
        return UIPasteboard.general.string
        #elseif canImport(AppKit)
        return NSPasteboard.general.string(forType: .string)
        #else
        return nil
        #endif
    }
}
