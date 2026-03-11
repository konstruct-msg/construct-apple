//
//  CatalystTextView.swift
//  Construct Messenger
//
//  On macOS Catalyst, SwiftUI's onKeyPress(.return) on a multiline TextField is
//  unreliable because UIKit's UITextView processes Return before SwiftUI sees it.
//  This UIViewRepresentable wraps a custom UITextView subclass that intercepts
//  pressesBegan, so plain Return = send and Shift+Return = newline.
//

#if targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

// MARK: - UITextView subclass that intercepts Return key

final class ReturnInterceptingTextView: UITextView {
    var onReturn: (() -> Void)?

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }
            if key.keyCode == .keyboardReturnOrEnter {
                if key.modifierFlags.contains(.shift) {
                    // Shift+Return → let UIKit insert newline normally
                    break
                }
                // Plain Return → send, consume event
                onReturn?()
                return
            }
        }
        super.pressesBegan(presses, with: event)
    }
}

// MARK: - UIViewRepresentable

struct CatalystGrowingTextView: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let canSend: Bool
    let onSend: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> ReturnInterceptingTextView {
        let tv = ReturnInterceptingTextView()
        tv.delegate = context.coordinator
        tv.font = .preferredFont(forTextStyle: .body)
        tv.backgroundColor = .clear
        tv.isScrollEnabled = false
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.onReturn = { [weak tv] in
            guard context.coordinator.parent.canSend else { return }
            // Strip any trailing newline that UIKit may have already inserted before
            // pressesBegan fires (shouldn't happen, but be safe)
            if let tv = tv {
                var current = tv.text ?? ""
                while current.hasSuffix("\n") { current.removeLast() }
                tv.text = current
                context.coordinator.parent.text = current
            }
            context.coordinator.parent.onSend()
        }
        context.coordinator.updatePlaceholder(tv, text: text)
        return tv
    }

    func updateUIView(_ tv: ReturnInterceptingTextView, context: Context) {
        context.coordinator.parent = self
        tv.onReturn = { [weak tv] in
            guard context.coordinator.parent.canSend else { return }
            if let tv = tv {
                var current = tv.text ?? ""
                while current.hasSuffix("\n") { current.removeLast() }
                tv.text = current
                context.coordinator.parent.text = current
            }
            context.coordinator.parent.onSend()
        }
        // Sync text from SwiftUI → UIKit (e.g., after clear on send)
        if tv.text != text {
            tv.text = text
        }
        context.coordinator.updatePlaceholder(tv, text: text)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CatalystGrowingTextView
        private weak var placeholderLabel: UILabel?

        init(_ parent: CatalystGrowingTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            updatePlaceholder(textView as! ReturnInterceptingTextView, text: textView.text)
        }

        func updatePlaceholder(_ tv: ReturnInterceptingTextView, text: String) {
            if placeholderLabel == nil {
                let label = UILabel()
                label.text = parent.placeholder
                label.font = tv.font
                label.textColor = .placeholderText
                label.numberOfLines = 1
                label.translatesAutoresizingMaskIntoConstraints = false
                tv.addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: tv.leadingAnchor),
                    label.topAnchor.constraint(equalTo: tv.topAnchor)
                ])
                placeholderLabel = label
            }
            placeholderLabel?.isHidden = !text.isEmpty
        }
    }
}
#endif
