//
//  DesktopToolbarSearchField.swift
//  Construct Desktop
//
//  The chat's message search as the window toolbar shows it while a search is open: the
//  system search field (`NSSearchField`), focused when it appears, closed by Escape.
//
//  `.searchable(placement: .toolbar)` keeps its field on screen at all times and takes the
//  toolbar's whole free width, so a control used now and then became the widest thing in the
//  window. `.searchToolbarBehavior(.minimize)`, which would collapse it, is not on macOS — and a
//  `.searchable` added only while searching would change the transcript view's identity and lose
//  its scroll position. The toolbar shows a magnifying-glass button instead, and this field in
//  its place while searching.
//

import AppKit
import SwiftUI

struct DesktopToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    /// Escape, or the field emptied and left — the search is over.
    let onEnd: () -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let field = FocusOnAppear()
        field.placeholderString = prompt
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: DesktopToolbarSearchField

        init(parent: DesktopToolbarSearchField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ note: Notification) {
            guard let field = note.object as? NSSearchField, field.stringValue.isEmpty else { return }
            parent.onEnd()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            parent.onEnd()
            return true
        }
    }

    /// Takes the keyboard as soon as it is in a window: the field appears because someone asked
    /// to search.
    private final class FocusOnAppear: NSSearchField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { window.makeFirstResponder(self) }
        }
    }
}
