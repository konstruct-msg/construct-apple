import SwiftUI

/// Canonical layout tokens for `ChatView` and every nested bubble / composer surface.
/// Prefer these over raw numbers. Radii always resolve through ``CTRadius``.
///
/// ## Radius rules (do not invent new values)
/// | Surface | Token | Why |
/// |---------|-------|-----|
/// | Text / system / file / profile bubbles | ``Bubble.cornerRadius`` → `CTRadius.control` (10) | Readable block, matches CTButton |
/// | Media / album tiles | ``Media.cornerRadius`` → same control | Align single + grid |
/// | Voice playback (any height / STT) | ``Voice.cornerRadius`` → `CTRadius.control` | Stable shape — no pill↔control jump on transcript |
/// | Composer text field (any height) | ``InputBar.cornerRadius`` → half of `controlHeight` | Stadium when 1-line; soft rect when multi — no jump |
/// | Attach circle / scroll FAB | pill (`CTRadius.pill`) | Fixed-height floating peers only |
enum ChatUIConstants {

    // MARK: - Typography

    enum Typography {
        static let messageTextSize: CGFloat = 15
        static let iOSmessageTextSize: CGFloat = 15
        static let macOSmessageTextSize: CGFloat = 13
        /// Timestamp, edited label, delivery icons under a bubble group.
        static let metaSize: CGFloat = 10
        /// Media captions, load-more, secondary labels.
        static let captionSize: CGFloat = 12
        /// System service lines, duration labels, reply-fallback copy.
        static let systemSize: CGFloat = 11
        /// Expanded voice STT transcript body.
        static let transcriptSize: CGFloat = 12
        /// Voice duration monospaced digit label.
        static let durationSize: CGFloat = 11
    }

    // MARK: - List / shell

    enum Shell {
        /// Default LazyVStack inter-row spacing (overridden per message by grouping).
        static let listSpacing: CGFloat = CTLayout.inlinePad
        /// Compact gap between consecutive messages from the same sender.
        static let withinGroupSpacing: CGFloat = 4
        /// Breathing room after the last message of a group (or sender change).
        static let betweenGroupSpacing: CGFloat = CTLayout.edgePad
        /// Clearance below the last bubble above the composer inset.
        static let messageBottomClearance: CGFloat = CTLayout.edgePad
        /// Horizontal inset around the floating composer.
        static let composerHorizontalPadding: CGFloat = CTLayout.inlinePad
        static let composerBottomPadding: CGFloat = CTLayout.inlinePad
        /// Top padding so messages clear the floating nav capsule.
        static let scrollContentTopPad: CGFloat = 70
        /// Extra band under the status bar covered by the top scrim.
        static let topScrimUnderSafeArea: CGFloat = CTLayout.navBarHeight + 24
        /// Floating nav / banner stack outer chrome.
        static let floatingChromeHorizontal: CGFloat = CTLayout.inlinePad
        static let floatingChromeTop: CGFloat = 4
        static let floatingChromeSpacing: CGFloat = CTLayout.inlinePad
        /// Lift scroll-to-bottom FAB above variable-height composer glass.
        static let scrollToBottomLift: CGFloat = 100
        /// Outer pad for reply/edit aux bars and flood banners (inside glass stack).
        static let auxOuterPad: CGFloat = 4
    }

    // MARK: - Message bubbles (text / shared chrome)

    enum Bubble {
        /// Text bubbles, file cards, profile shares, voice-with-transcript.
        static let cornerRadius: CGFloat = CTRadius.control
        static let strokeWidth: CGFloat = 0.5
        static let selectionStrokeWidth: CGFloat = 2
        /// Hard cap for voice / media-adjacent bubbles.
        static let maxWidth: CGFloat = 360
        /// Fraction of container width available to a bubble column.
        static let maxWidthFraction: CGFloat = 0.7
        static let minColumnWidth: CGFloat = 120
        /// Fallback container width before geometry settles.
        static let defaultContainerWidth: CGFloat = 390
        /// Content padding inside a text / file bubble.
        static let horizontalPadding: CGFloat = CTLayout.edgePad
        static let verticalPadding: CGFloat = CTLayout.inlinePad
        /// Tighter top padding when a reply strip is already above the body.
        static let tightVerticalPadding: CGFloat = 4
        /// Stack gap between body lines / meta chips.
        static let stackSpacing: CGFloat = 4
        /// Horizontal gap between selection checkbox and bubble column.
        static let rowSpacing: CGFloat = CTLayout.inlinePad
        /// Opposite-side gutter so bubbles don't span full width.
        static let sideGutter: CGFloat = 60
        /// Accent bar on reply strip inside a bubble.
        static let replyAccentWidth: CGFloat = 2
        static let replyThumbnailSize: CGFloat = 40
        /// Compact compose-bar reply strip (was 36 — made the aux bar too tall).
        static let replyBarThumbnailSize: CGFloat = 28
        /// Horizontal inset on the timestamp / status row under a group.
        static let metaHorizontalPadding: CGFloat = 4
    }

    /// Reaction badge on a bubble, and the quick-set capsule.
    enum Reaction {
        static let badgeFontSize: CGFloat = 14
        static let badgePadH: CGFloat = 6
        static let badgePadV: CGFloat = 4
        /// Overlaps the bubble corner slightly. Horizontal corner is ``badgeAlignment``.
        static let badgeOverlap: CGFloat = 8

        static let capsuleEmojiSize: CGFloat = 22
        static let capsuleItem: CGFloat = 36
        static let capsuleItemSpacing: CGFloat = 4
        static let capsuleDot: CGFloat = 4
        static let capsuleHeight: CGFloat = 44
        static let capsuleGap: CGFloat = CTLayout.inlinePad

        /// Timestamp lives on the author's side (sent = trailing). The like sits
        /// on the other corner so the two do not stack.
        static func badgeAlignment(isSentByMe: Bool) -> Alignment {
            isSentByMe ? .bottomLeading : .bottomTrailing
        }
    }

    /// Swipe-to-reply, tuned to stay out of the interactive back gesture's way.
    ///
    /// The two gestures point the same direction, and incoming bubbles sit against the
    /// leading edge — exactly where the system pop lives. Without these limits a swipe
    /// meant to leave the chat landed on whatever bubble it started over and replied to it.
    enum ReplySwipe {
        // There is no leading-edge exclusion any more. It existed because the reply swipe and
        // the interactive pop both travelled right, so they had to be separated by where the
        // drag began — a 44pt strip conceded to the pop, which both leaked (a back swipe
        // starting inboard quoted a message) and cost the leftmost 44pt of every incoming
        // bubble. The reply swipe now travels left; direction tells them apart on its own.
        /// Horizontal travel must beat vertical by this factor. The old test was `h > v`,
        /// which any lazy diagonal satisfied.
        static let directionRatio: CGFloat = 1.5
        static let minimumDistance: CGFloat = 20
        /// The bubble follows the finger at half speed, capped here.
        static let maxOffset: CGFloat = 60
        /// Offset at which releasing commits the reply (≈80pt of travel).
        static let commitOffset: CGFloat = 40
        /// Indicator fades in past this offset.
        static let indicatorThreshold: CGFloat = 10
    }

    // MARK: - Voice playback bubble

    enum Voice {
        /// Always matches text bubbles. Do not switch on transcript expand —
        /// pill↔control used to jump the outline when STT appeared.
        static let cornerRadius: CGFloat = CTRadius.control

        static let controlWidth: CGFloat = 38
        static let waveformHeight: CGFloat = 28
        static let durationWidth: CGFloat = 34
        static let toggleSize: CGFloat = 20
        static let playerSpacing: CGFloat = CTLayout.inlinePad
        static let horizontalPadding: CGFloat = CTLayout.chromeGap
        static let verticalPadding: CGFloat = CTLayout.inlinePad
        static let playIconSize: CGFloat = 14
        static let toggleIconSize: CGFloat = 13
        static let strokeWidth: CGFloat = 0.5

        static var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        }
    }

    // MARK: - Media / album

    enum Media {
        static let cornerRadius: CGFloat = CTRadius.control
        static let badgeCornerRadius: CGFloat = CTRadius.badge
        /// Progress chip over a video poster while downloading.
        static let overlayChipRadius: CGFloat = CTLayout.edgePad
        static let playButtonSize: CGFloat = 54
        static let albumTileGap: CGFloat = 2
        static let selectionStrokeWidth: CGFloat = 2
    }

    // MARK: - Reply focus (soft dim, not Apple-style isolation)

    /// When the user is composing a reply or peeks a reply chain, non-focused
    /// bubbles fade slightly. Layout and hit-testing stay unchanged — only opacity.
    /// Idle chat is unaffected (`replyFocusIds` empty → full opacity).
    enum ReplyFocus {
        /// Other messages while focus is active. ~0.5 keeps CT density readable;
        /// Apple Messages goes much lower (almost isolation).
        static let dimmedOpacity: Double = 0.48
        static let focusedOpacity: Double = 1.0
        static let animationDuration: Double = 0.22
        /// Auto-clear for strip-tap “peek” when not also composing a reply.
        static let peekHoldNanoseconds: UInt64 = 2_500_000_000
    }

    // MARK: - Composer input bar

    enum InputBar {
        /// Fixed for all field heights: half of single-line control height.
        /// One-line bar looks stadium-like; multi-line stays the same family (no
        /// pill↔control jump). Does not clamp to height/2 so tall text is not oval-clipped.
        static let cornerRadius: CGFloat = CTLayout.controlHeight / 2
        /// Target single-line control height (attach / send / scroll FAB).
        static let height: CGFloat = CTLayout.controlHeight
        static let horizontalPadding: CGFloat = CTLayout.edgePad
        /// Leading inset inside the text field capsule.
        static let textLeadingPad: CGFloat = CTLayout.sectionGap
        static let textVerticalPad: CGFloat = 11
        static let trailingIconSize: CGFloat = 28
        /// Spacing between attach circle and text capsule.
        static let attachFieldGap: CGFloat = CTLayout.chromeGap
        /// Outer horizontal pad of the attach+field row.
        static let rowOuterPad: CGFloat = 4
        /// Gap between reply/edit aux bar and the attach+field row.
        static let auxBarGap: CGFloat = CTLayout.inlinePad
        /// Voice recording / preview bar height.
        static let voiceChromeHeight: CGFloat = 52
        static let voiceChromeIconSize: CGFloat = 22
    }
}
