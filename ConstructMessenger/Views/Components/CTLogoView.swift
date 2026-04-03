//
//  CTLogoView.swift
//  Construct Messenger
//
//  Konstrukt sphere logo rendered as ASCII terminal art.
//

import SwiftUI

struct CTLogoView: View {

    /// Bounding square side-length in points.
    var size: CGFloat = 134
    var color: Color = Color.CT.accent

    // Font size used to compute the art's natural dimensions.
    // Natural height ≈ lineCount × (fontSize × 1.25)
    // Natural width  ≈ maxCharCount × (fontSize × 0.60)
    private static let fontSize:      CGFloat = 4.5
    private static let naturalWidth:  CGFloat = 152   // ~56 chars × 0.60 × 4.5
    private static let naturalHeight: CGFloat = 208   // ~37 lines × 1.25 × 4.5

    var body: some View {
        let scale = size / max(Self.naturalWidth, Self.naturalHeight)
        Text(Self.art)
            .font(.system(size: Self.fontSize, design: .monospaced))
            .foregroundStyle(color)
            .lineSpacing(0)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: true, vertical: true)
            .scaleEffect(scale, anchor: .center)
            .frame(width: size, height: size)
    }

    // MARK: - ASCII Art

    // swiftlint:disable:next line_length
    static let art: String =
        "   :@@@@\n" +
        " @@@@@@@@@@@\n" +
        "=@@@@@@@@@@@@@@\n" +
        "@@@@@.......@@@@@\n" +
        "@@@@#.........@@@@\n" +
        "@@@@  ..... . ..@@@@\n" +
        "@@@........ . ..@@@@         @@@@@@@@@@\n" +
        "@@@....... .....@@@.       #@@@@@@@@@@@@@\n" +
        "@@@ ...........@@@         @@@@@:.....@@@@@\n" +
        "@@@....  .......@@@@      @@@@+.........@@@@*\n" +
        "@@@. .... .... .@@@#     @@@@............@@@@\n" +
        "@@... ...... ...@@@    +@@@... ......  ..*@@@\n" +
        "@@ ...........+@@@    @@@.......... . ....@@@@\n" +
        "@@  ......... @@@@   @@@*.... ....  .....@@@\n" +
        "+@@..........@@@@@@@@@@.. .. ... ........@@#\n" +
        "@@@........ .@@@@@@... ......... ......@@@\n" +
        "@@@......... ...... ............. ...+@@\n" +
        "=@@...... ..... ....... ... ...........@@\n" +
        " @@......... ........ ... . ..........@@\n" +
        " @@...................................@@=\n" +
        " @@+............... ...... ...... ...@@@\n" +
        " @@@.............. .. .......... ...@@@\n" +
        " *@@........................... ...@@+\n" +
        "  @@@.............................. @@\n" +
        "  @@@@.................. ........@@\n" +
        "   @@@*... ........... ......... .@@\n" +
        "    @@@@.......-@@@@@@@@....... @@@\n" +
        "    *@@@@....@@@@@@@@@@@@@@..... @@@\n" +
        "      @@@@@.:@@@@@  @@@@@@@....@@@\n" +
        "       @@@@@@@@@@     @@@@@....@@@\n" +
        "         @@@@@@@@      @@@@.. @@@\n" +
        "                        @@@@.....@@@@\n" +
        "                         @@@@... #@@@@\n" +
        "                          @@@@@. @@@@@\n" +
        "                           @@@@@@@@@@@@+\n" +
        "                             @@@@@@@@@@@\n" +
        "                                @@@@:"
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.CT.bg.ignoresSafeArea()
        VStack(spacing: 24) {
            CTLogoView(size: 134)
            CTLogoView(size: 64, color: Color.CT.text)
            CTLogoView(size: 200)
        }
    }
}
