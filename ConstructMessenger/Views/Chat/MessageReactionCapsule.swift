//
//  MessageReactionCapsule.swift
//  Construct Messenger
//
//  Small glass quick-set (popular six + plus). Not the message-action menu.
//  Plus opens the system emoji keyboard for any other grapheme.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct MessageReactionCapsule: View {
    let currentEmoji: String?
    let onPick: (String) -> Void
    let onPickMore: () -> Void

    var body: some View {
        HStack(spacing: ChatUIConstants.Reaction.capsuleItemSpacing) {
            ForEach(ReactionReducer.quickSet, id: \.self) { emoji in
                Button {
                    onPick(emoji)
                } label: {
                    VStack(spacing: ChatUIConstants.Bubble.stackSpacing) {
                        Text(emoji)
                            .font(.system(size: ChatUIConstants.Reaction.capsuleEmojiSize))
                        Circle()
                            .fill(currentEmoji == emoji ? Color.CT.accent : Color.clear)
                            .frame(
                                width: ChatUIConstants.Reaction.capsuleDot,
                                height: ChatUIConstants.Reaction.capsuleDot
                            )
                    }
                    .frame(
                        width: ChatUIConstants.Reaction.capsuleItem,
                        height: ChatUIConstants.Reaction.capsuleItem
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    currentEmoji == emoji
                        ? NSLocalizedString("reaction_remove", comment: "")
                        : emoji
                )
            }

            Button(action: onPickMore) {
                Image(systemName: "plus.circle")
                    .font(.system(size: ChatUIConstants.Reaction.capsuleEmojiSize))
                    .foregroundColor(Color.CT.accent)
                    .frame(
                        width: ChatUIConstants.Reaction.capsuleItem,
                        height: ChatUIConstants.Reaction.capsuleItem
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("reaction_pick_more", comment: ""))
        }
        .padding(.horizontal, CTLayout.inlinePad)
        .padding(.vertical, ChatUIConstants.Bubble.tightVerticalPadding)
        .glassCapsule()
    }
}

struct ReactionEmojiPickerSheet: View {
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            CTNavBar(
                title: NSLocalizedString("react", comment: ""),
                showBack: true,
                isModal: true,
                backAction: { dismiss() }
            )
            Text(NSLocalizedString("reaction_pick_more", comment: ""))
                .font(CTFont.regular(ChatUIConstants.Typography.captionSize))
                .foregroundColor(Color.CT.textDim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, CTLayout.edgePad)
                .padding(.top, CTLayout.inlinePad)
            #if os(iOS)
            ReactionEmojiKeyboardHost { emoji in
                onPick(emoji)
                dismiss()
            }
            .frame(maxWidth: .infinity)
            .frame(height: CTLayout.controlHeight)
            .padding(.horizontal, CTLayout.edgePad)
            .padding(.top, CTLayout.inlinePad)
            #else
            ReactionMacEmojiField { emoji in
                onPick(emoji)
                dismiss()
            }
            .padding(.horizontal, CTLayout.edgePad)
            .padding(.top, CTLayout.inlinePad)
            #endif
            Spacer()
        }
        .ctBackground()
    }
}

#if os(iOS)
/// Prefers the emoji keyboard. Inserted grapheme is the pick.
private struct ReactionEmojiKeyboardHost: UIViewRepresentable {
    var onPick: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIView(context: Context) -> UITextField {
        let field = EmojiPreferringTextField()
        field.delegate = context.coordinator
        field.keyboardAppearance = .dark
        field.textAlignment = .center
        field.tintColor = UIColor(Color.CT.accent)
        field.textColor = UIColor(Color.CT.text)
        field.backgroundColor = UIColor(Color.CT.bgMsg)
        field.layer.cornerRadius = CTRadius.card
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        DispatchQueue.main.async { field.becomeFirstResponder() }
        return field
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        context.coordinator.onPick = onPick
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var onPick: (String) -> Void
        init(onPick: @escaping (String) -> Void) { self.onPick = onPick }

        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if ReactionReducer.isValidEmoji(trimmed) {
                onPick(trimmed)
            }
            return false
        }
    }
}

private final class EmojiPreferringTextField: UITextField {
    override var textInputContextIdentifier: String? { "" }

    override var textInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" }
            ?? super.textInputMode
    }
}
#endif

#if os(macOS)
private struct ReactionMacEmojiField: View {
    let onPick: (String) -> Void
    @State private var text = ""

    var body: some View {
        TextField(NSLocalizedString("react", comment: ""), text: $text)
            .textFieldStyle(.plain)
            .font(CTFont.regular(ChatUIConstants.Typography.messageTextSize))
            .foregroundColor(Color.CT.text)
            .padding(CTLayout.inlinePad)
            .background(Color.CT.bgMsg)
            .clipShape(CTShape.card())
            .onChange(of: text) { _, new in
                let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
                if ReactionReducer.isValidEmoji(trimmed) {
                    onPick(trimmed)
                }
            }
    }
}
#endif
