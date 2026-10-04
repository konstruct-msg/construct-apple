//
//  ReactionQuickSet.swift
//  Construct Messenger
//
//  The five emoji at the head of the message menu. They start as a popular set and become the
//  user's own: every reaction this device sends is counted, old uses fade, and an emoji that has
//  been used more lately than the weakest of the five takes that one's place.
//
//  Two properties are the point, and the tests pin both:
//  - **Gradual.** A one-off reaction does not enter the row; a few uses close together do. The
//    popular set is seeded with scores a newcomer has to earn its way past.
//  - **Stable.** An emoji that enters takes the evicted one's slot, and the others keep theirs.
//    Sorting by score would reshuffle the row on every reaction, and the reader's thumb learns
//    positions, not scores.
//
//  The counts never leave this device: they are a habit, not a message, and nothing is sent to a
//  peer, a sibling device or the server.
//

import Foundation
import Observation

struct ReactionQuickSet: Codable, Equatable {
    /// Five, with the plus after them, is what a menu palette shows without scrolling; a sixth
    /// pushed the plus out of sight behind a scroll nobody would guess at (seen 2026-10-04).
    /// Android's row, which is not a system palette, holds six.
    static let size = 5

    /// The row before anything is learned, in display order. The first is the double-tap like.
    /// The Instagram six less 😠, which gave its place to the plus.
    static let defaults = ["❤️", "😂", "😮", "😢", "🔥"]

    /// What every count is multiplied by when another reaction is recorded. At 0.9 a use is worth
    /// about a third of itself ten reactions later.
    static let decay = 0.9

    /// The first default's starting score; each later one starts `seedStep` lower, so the last of
    /// them is the first to give way. At 3 an emoji enters on its third use in a row: after two its
    /// 1.9 is still under the last default's 2.8 × 0.9², after three its 2.71 is over 2.8 × 0.9³.
    static let seed = 3.0
    static let seedStep = 0.05

    /// Counts below this, for emoji not in the row, are forgotten — the table stays the size of
    /// what the user actually uses.
    static let forgetBelow = 0.05

    private(set) var slots: [String]
    private(set) var scores: [String: Double]

    static let initial = ReactionQuickSet(
        slots: defaults,
        scores: Dictionary(uniqueKeysWithValues: defaults.enumerated().map {
            ($0.element, seed - Double($0.offset) * seedStep)
        })
    )

    /// The row after the user reacted with `emoji`.
    func recording(_ emoji: String) -> ReactionQuickSet {
        var scores = scores.mapValues { $0 * Self.decay }
        scores[emoji, default: 0] += 1
        var slots = slots
        if !slots.contains(emoji),
           // The first of the weakest gives way, so ties evict in a fixed order.
           let weakest = slots.indices.min(by: { scores[slots[$0], default: 0] < scores[slots[$1], default: 0] }),
           scores[emoji, default: 0] > scores[slots[weakest], default: 0]
        {
            slots[weakest] = emoji
        }
        scores = scores.filter { $0.value >= Self.forgetBelow || slots.contains($0.key) }
        return ReactionQuickSet(slots: slots, scores: scores)
    }

    /// A stored row that does not have `size` distinct entries is not one this code wrote.
    var isWellFormed: Bool {
        slots.count == Self.size && Set(slots).count == Self.size
    }
}

/// The row this device shows, kept in `UserDefaults`.
@MainActor
@Observable
final class ReactionQuickSetStore {
    static let shared = ReactionQuickSetStore()

    static let defaultsKey = "construct.reactions.quickSet.v1"

    private(set) var quickSet: ReactionQuickSet

    var slots: [String] { quickSet.slots }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode(ReactionQuickSet.self, from: data),
           stored.isWellFormed
        {
            quickSet = stored
        } else {
            quickSet = .initial
        }
    }

    func record(_ emoji: String) {
        quickSet = quickSet.recording(emoji)
        if let data = try? JSONEncoder().encode(quickSet) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
