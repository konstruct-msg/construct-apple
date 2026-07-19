import SwiftUI

/// Canonical layout tokens for `ChatView` and every nested bubble / composer surface.
/// Prefer these over raw numbers. Radii always resolve through ``CTRadius``.
///
/// ## Radius rules (do not invent new values)
/// | Surface | Token | Why |
/// |---------|-------|-----|
/// | Text / system / file / profile bubbles | ``Bubble.cornerRadius`` → `CTRadius.control` (10) | Readable block, matches CTButton |
/// | Media / album tiles | ``Media.cornerRadius`` → same control | Align single + grid |
/// | Voice **waveform-only** | ``Voice.cornerRadius`` → `CTRadius.pill` | Compact chrome peer of composer |
/// | Voice **with transcript** | ``Voice.transcriptCornerRadius`` → `CTRadius.control` | Pill clamps to height/2 and oval-clips multi-line STT text |
/// | Composer glass / attach / FAB | ``InputBar.cornerRadius`` → `CTRadius.pill` | True capsule |
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
        static let replyBarThumbnailSize: CGFloat = 36
        /// Horizontal inset on the timestamp / status row under a group.
        static let metaHorizontalPadding: CGFloat = 4
    }

    // MARK: - Voice playback bubble

    enum Voice {
        /// Waveform-only (compact height) — full capsule.
        static let cornerRadius: CGFloat = CTRadius.pill
        /// With expanded transcript — same as text bubbles.
        /// **Invariant**: never use ``cornerRadius`` (pill) when transcript is shown;
        /// ContinuousRoundedRect clamps radius to height/2 and clips multi-line STT text.
        static let transcriptCornerRadius: CGFloat = CTRadius.control

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

        /// Corner radius for the current voice chrome state.
        static func cornerRadius(transcriptShown: Bool) -> CGFloat {
            transcriptShown ? transcriptCornerRadius : cornerRadius
        }

        static func shape(transcriptShown: Bool) -> RoundedRectangle {
            RoundedRectangle(
                cornerRadius: cornerRadius(transcriptShown: transcriptShown),
                style: .continuous
            )
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
        /// Full capsule — attach circle peer.
        static let cornerRadius: CGFloat = CTRadius.pill
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
        /// Voice recording / preview bar height.
        static let voiceChromeHeight: CGFloat = 52
        static let voiceChromeIconSize: CGFloat = 22
    }
}
