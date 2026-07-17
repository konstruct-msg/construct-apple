import SwiftUI

enum ChatUIConstants {
    enum Typography {
        static let messageTextSize: CGFloat = 15
        static let iOSmessageTextSize: CGFloat = 15
        static let macOSmessageTextSize: CGFloat = 13
    }

    enum Bubble {
        /// Text bubbles share ``CTRadius.control`` with primary buttons.
        static let cornerRadius: CGFloat = CTRadius.control
        static let strokeWidth: CGFloat = 0.5
        static let maxWidth: CGFloat = 360
        static let horizontalPadding: CGFloat = CTLayout.chromeGap
        static let verticalPadding: CGFloat = CTLayout.inlinePad
        static let rowSpacing: CGFloat = CTLayout.inlinePad
    }

    enum Voice {
        /// Voice chrome uses ``CTRadius.pill`` (same family as composer glass).
        static let cornerRadius: CGFloat = CTRadius.pill
        static let controlWidth: CGFloat = 38
        static let waveformHeight: CGFloat = 28
        static let durationWidth: CGFloat = 34
        static let transcriptButtonSpacing: CGFloat = 4
    }

    enum InputBar {
        /// Full capsule — ``CTRadius.pill`` (attach circle peer).
        static let cornerRadius: CGFloat = CTRadius.pill
        /// Target single-line control height (attach / send / scroll FAB).
        static let height: CGFloat = CTLayout.controlHeight
        static let horizontalPadding: CGFloat = CTLayout.edgePad
    }
}
