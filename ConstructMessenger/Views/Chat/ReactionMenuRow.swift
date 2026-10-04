//
//  ReactionMenuRow.swift
//  Construct Messenger
//
//  Reactions at the head of the message's context menu: the five of `ReactionQuickSetStore` and a
//  plus for every other emoji. A native palette row of the menu itself, as on Android, where the
//  quick row heads the long-press menu.
//
//  Until 2026-10-04 the menu had a React item that, once the menu closed, inserted a glass capsule
//  as a row above or below the bubble. The row went in while the menu's dismissal was still
//  animating, and for a beat the capsule showed as a clipped strip — reported from device twice,
//  patched with transactions that vetoed the animation twice, and back. Inside the menu there is
//  no insertion to animate, and it is one tap fewer.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The menu's reaction row. Put first in a `.contextMenu`.
struct ReactionMenuRow: View {
    /// The reaction this user has on the message, if any. Tapping it again takes it off.
    let currentEmoji: String?
    let onPick: (String) -> Void
    let onPickMore: () -> Void

    var body: some View {
        ControlGroup {
            ForEach(ReactionQuickSetStore.shared.slots, id: \.self) { emoji in
                Button {
                    onPick(emoji)
                } label: {
                    EmojiMenuGlyph.image(emoji, marked: emoji == currentEmoji)
                }
                .accessibilityLabel(
                    emoji == currentEmoji
                        ? NSLocalizedString("reaction_remove", comment: "")
                        : emoji
                )
            }
            Button(action: onPickMore) {
                Image(systemName: "plus")
            }
            .accessibilityLabel(NSLocalizedString("reaction_pick_more", comment: ""))
        }
        .controlGroupStyle(.palette)
        // A palette keeps its menu open after a tap, as a colour picker would; a reaction is the
        // whole job, so the menu closes on it (seen open on the simulator 2026-10-04).
        .menuActionDismissBehavior(.enabled)
    }
}

/// An emoji as a menu image. A palette row draws its items as images, and tints a template image
/// in the menu's text colour — an emoji drawn that way is a grey silhouette. Drawn into a bitmap
/// and kept in its own colours.
enum EmojiMenuGlyph {
    static let side: CGFloat = 28
    static let markHeight: CGFloat = 4

    @MainActor
    static func image(_ emoji: String, marked: Bool) -> Image {
        #if canImport(UIKit)
        let size = CGSize(width: side, height: side + markHeight * 2)
        let rendered = UIGraphicsImageRenderer(size: size).image { _ in
            draw(emoji, marked: marked, in: size, accent: UIColor(Color.CT.accent))
        }
        return Image(uiImage: rendered.withRenderingMode(.alwaysOriginal))
        #else
        let size = CGSize(width: side, height: side + markHeight * 2)
        let rendered = NSImage(size: size, flipped: true) { _ in
            draw(emoji, marked: marked, in: size, accent: NSColor(Color.CT.accent))
            return true
        }
        rendered.isTemplate = false
        return Image(nsImage: rendered)
        #endif
    }

    #if canImport(UIKit)
    private typealias PlatformFont = UIFont
    private typealias PlatformColor = UIColor
    #else
    private typealias PlatformFont = NSFont
    private typealias PlatformColor = NSColor
    #endif

    /// The emoji centred in a square, and under it a dot when it is the reaction already set —
    /// the same mark the capsule and Android's row use.
    private static func draw(_ emoji: String, marked: Bool, in size: CGSize, accent: PlatformColor) {
        let text = NSAttributedString(
            string: emoji,
            attributes: [.font: PlatformFont.systemFont(ofSize: side * 0.82)]
        )
        let bounds = text.size()
        text.draw(at: CGPoint(x: (size.width - bounds.width) / 2, y: (side - bounds.height) / 2))
        guard marked else { return }
        let dot = CGRect(
            x: (size.width - markHeight) / 2,
            y: side + markHeight / 2,
            width: markHeight,
            height: markHeight
        )
        accent.setFill()
        #if canImport(UIKit)
        UIBezierPath(ovalIn: dot).fill()
        #else
        NSBezierPath(ovalIn: dot).fill()
        #endif
    }
}

/// The full picker behind the menu row's plus.
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
                                .font(CTFont.ui(ChatUIConstants.Typography.captionSize, weight: .medium))
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
