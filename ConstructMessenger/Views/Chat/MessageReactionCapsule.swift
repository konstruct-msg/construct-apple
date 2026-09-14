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

/// The full picker behind the capsule's plus.
///
/// A grid of every emoji this OS can draw, grouped, from `EmojiCatalogue`. It replaces a
/// `UITextField` that asked iOS for the emoji keyboard by overriding `textInputMode` — a preference
/// the system does not have to honour, and on device did not: the screen showed the letter keyboard
/// over an empty box, and every letter typed into it was forwarded as a reaction. One arrived on the
/// far side as `set(emoji: "H")`.
///
/// One implementation for both platforms. The two field variants it replaces differed only in which
/// keyboard they hoped for.
struct ReactionEmojiPickerSheet: View {
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private let columns = [
        GridItem(.adaptive(minimum: ChatUIConstants.Reaction.pickerCell), spacing: CTLayout.inlinePad)
    ]

    var body: some View {
        VStack(spacing: 0) {
            CTNavBar(
                title: NSLocalizedString("react", comment: ""),
                showBack: true,
                isModal: true,
                backAction: { dismiss() }
            )
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: CTLayout.inlinePad, pinnedViews: [.sectionHeaders]) {
                    ForEach(EmojiCatalogue.groups) { group in
                        Section {
                            ForEach(group.emoji, id: \.self) { emoji in
                                Button {
                                    onPick(emoji)
                                    dismiss()
                                } label: {
                                    Text(emoji)
                                        .font(.system(size: ChatUIConstants.Reaction.pickerEmojiSize))
                                        .frame(
                                            width: ChatUIConstants.Reaction.pickerCell,
                                            height: ChatUIConstants.Reaction.pickerCell
                                        )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(emoji)
                            }
                        } header: {
                            Text("> " + NSLocalizedString(group.id, comment: "").uppercased())
                                .font(CTFont.medium(ChatUIConstants.Typography.captionSize))
                                .tracking(2)
                                .foregroundColor(Color.CT.textDim)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, ChatUIConstants.Bubble.tightVerticalPadding)
                                .background(Color.CT.bg)
                        }
                    }
                }
                .padding(.horizontal, CTLayout.edgePad)
                .padding(.top, CTLayout.inlinePad)
            }
        }
        .ctBackground()
    }
}
