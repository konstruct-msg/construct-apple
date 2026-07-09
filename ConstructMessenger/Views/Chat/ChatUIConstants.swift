import SwiftUI

enum ChatUIConstants {
    enum Typography {
        static let messageTextSize: CGFloat = 15
        static let iOSmessageTextSize: CGFloat = 15
        static let macOSmessageTextSize: CGFloat = 13
    }

    enum Bubble {
        static let cornerRadius: CGFloat = 10
        static let strokeWidth: CGFloat = 0.5
        static let maxWidth: CGFloat = 360
        static let horizontalPadding: CGFloat = 10
        static let verticalPadding: CGFloat = 8
        static let rowSpacing: CGFloat = 8
    }

    enum Voice {
        static let controlWidth: CGFloat = 38
        static let waveformHeight: CGFloat = 28
        static let durationWidth: CGFloat = 34
        static let transcriptButtonSpacing: CGFloat = 4
    }

    enum InputBar {
        static let cornerRadius: CGFloat = 18
        static let height: CGFloat = 52
        static let horizontalPadding: CGFloat = 12
    }
}
