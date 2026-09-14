//
//  EmojiCatalogue.swift
//  Construct Messenger
//
//  Every emoji the picker can offer, grouped, derived from Unicode rather than typed out.
//
//  The "more reactions" screen used to be a `UITextField` that asked iOS for the emoji keyboard by
//  overriding `textInputMode`. That is a preference, not an instruction, and on device the screen
//  showed the ordinary letter keyboard above an empty box — reported 2026-08-22 as "при переходе на
//  все остальные эмодзи там ничего нет". Worse, the field forwarded whatever was typed, so the
//  letters keyboard was live: device log 2026-08-21 14:39:42 has a peer's reaction arrive as
//  `set(emoji: "H")`. `ReactionReducer.isValidEmoji` now refuses that, and this removes the surface
//  that produced it.
//
//  Ranges rather than a table: a table of 3,000 emoji is a file nobody reviews and that is stale the
//  day a Unicode version ships. These are the published block ranges, filtered through
//  `Unicode.Scalar.Properties` — so what the catalogue offers is exactly what this OS can draw, and
//  a new iOS with new emoji fills in without an edit here.
//

import Foundation

enum EmojiCatalogue {

    struct Group: Identifiable, Equatable {
        /// Localisation key for the section header.
        let id: String
        let emoji: [String]
    }

    /// The blocks each group is drawn from. Named by what a reader would call them, not by their
    /// Unicode block names, which split "smileys" across four separate ranges.
    private static let groupRanges: [(id: String, ranges: [ClosedRange<UInt32>])] = [
        // 0x1F910…0x1F92F stops short of 0x1F930, where the gestures/people block begins — the
        // ranges must not overlap, and `testNoEmojiIsOfferedTwice` is what says so.
        ("emoji_group_smileys", [0x1F600...0x1F64F, 0x1F910...0x1F92F, 0x1F970...0x1F97A]),
        ("emoji_group_people",  [0x1F440...0x1F4AA, 0x1F930...0x1F93E, 0x1F9D0...0x1F9DF]),
        ("emoji_group_nature",  [0x1F400...0x1F43F, 0x1F980...0x1F9AE, 0x1F330...0x1F343]),
        ("emoji_group_food",    [0x1F345...0x1F37F, 0x1F950...0x1F96F]),
        ("emoji_group_activity",[0x1F380...0x1F3CA, 0x1F93F...0x1F94F]),
        ("emoji_group_travel",  [0x1F680...0x1F6C5, 0x1F3E0...0x1F3F0]),
        ("emoji_group_objects", [0x1F4BB...0x1F4FF, 0x1F526...0x1F53D]),
        ("emoji_group_symbols", [0x1F500...0x1F525, 0x2764...0x2764, 0x1F4AF...0x1F4AF])
    ]

    /// Built once. The scan is a few thousand scalar property reads — cheap, but not per keystroke.
    static let groups: [Group] = groupRanges.compactMap { group in
        let emoji = group.ranges
            .flatMap { $0 }
            .compactMap { codePoint -> String? in
                guard let scalar = Unicode.Scalar(codePoint) else { return nil }
                // Older emoji default to *text* presentation and are only drawn as emoji with
                // U+FE0F after them — ❤ is the one everybody notices, and it is the first entry of
                // the quick set. Offer the presentation form, which is also the form the peer's
                // validator accepts.
                let bare = String(scalar)
                let candidate = scalar.properties.isEmojiPresentation ? bare : bare + "\u{FE0F}"
                // The same predicate the wire uses. A catalogue that offered something the
                // validator then refused would be a picker with dead keys in it — and the two
                // agreeing is exactly what stopped being true when the keyboard was the picker.
                guard ReactionReducer.isValidEmoji(candidate) else { return nil }
                return candidate
            }
        return emoji.isEmpty ? nil : Group(id: group.id, emoji: emoji)
    }

    /// Case- and diacritic-insensitive contains, over the group headings' localised text.
    ///
    /// Deliberately not a search over emoji *names*: iOS exposes no name table, and shipping one is
    /// the same staleness problem the ranges avoid. Filtering by section is what can be done
    /// honestly, so it is what the screen offers.
    static func groups(matching query: String) -> [Group] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return groups }
        return groups.filter { group in
            NSLocalizedString(group.id, comment: "")
                .range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
