//
//  ThemeContrastTests.swift
//  ConstructMessengerTests
//
//  The palette's readability, asserted from the tokens themselves.
//

#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import Construct_Messenger

/// WCAG 2.1 contrast over the resolved token colours, in both themes.
///
/// These numbers were chosen deliberately (construct-docs
/// `client/ios/NATIVE_AFFORDANCE_MIGRATION.md` §Stage 1) and the reason for a test rather than a
/// comment is that nothing else notices when a colour drifts: `accent` sat at 3.97 on the dark
/// background for months, and the only symptom was that people could not find the button.
final class ThemeContrastTests: XCTestCase {

    /// 4.5:1 — normal-size text. 3:1 — icons, and text at 24pt or bolded 18.6pt+.
    private let textFloor: Double = 4.5
    private let nonTextFloor: Double = 3.0

    // MARK: - Text pairs

    func testAccentIsReadableAsTextOnEverySurfaceItLandsOn() {
        // Accent is text, not just a fill: section headers sit on `bg`, and action rows inside
        // CTSectionGroup sit on `bgMsg`.
        for style in [UIUserInterfaceStyle.dark, .light] {
            assertContrast(.CT.accent, on: .CT.bg, atLeast: textFloor, style: style, "accent on bg")
            assertContrast(.CT.accent, on: .CT.bgMsg, atLeast: textFloor, style: style, "accent on bgMsg")
        }
    }

    func testPrimaryButtonLabelIsReadableOnItsOwnFill() {
        // CTButton draws its label in `Color.CT.bg` over `accent`. This pair is the main call to
        // action in the app and it was the one below the floor.
        for style in [UIUserInterfaceStyle.dark, .light] {
            assertContrast(.CT.bg, on: .CT.accent, atLeast: textFloor, style: style, "CTButton label on accent")
        }
    }

    func testSecondaryTextIsReadableOnCardsAndBubbles() {
        // textDim's usual home is a card, not the background — #818181 passed on `bg` and failed
        // on `bgMsg`, which is where timestamps and row values actually sit.
        for style in [UIUserInterfaceStyle.dark, .light] {
            assertContrast(.CT.textDim, on: .CT.bg, atLeast: textFloor, style: style, "textDim on bg")
            assertContrast(.CT.textDim, on: .CT.bgMsg, atLeast: textFloor, style: style, "textDim on bgMsg")
            assertContrast(.CT.textDim, on: .CT.outMsgBg, atLeast: textFloor, style: style, "textDim on outMsgBg")
        }
    }

    func testPrimaryTextAndBubbleTextAreReadable() {
        for style in [UIUserInterfaceStyle.dark, .light] {
            assertContrast(.CT.text, on: .CT.bg, atLeast: textFloor, style: style, "text on bg")
            assertContrast(.CT.text, on: .CT.bgMsg, atLeast: textFloor, style: style, "text on bgMsg")
            assertContrast(.CT.outMsgText, on: .CT.outMsgBg, atLeast: textFloor, style: style, "outMsgText on outMsgBg")
        }
    }

    // MARK: - Non-text pairs

    func testAccentDimClearsTheIconFloorOnly() {
        // accentDim is a fill and hover state. No dim partner of this accent reaches 4.5 on the
        // dark background, which is why its former text uses were moved to `accent`.
        for style in [UIUserInterfaceStyle.dark, .light] {
            assertContrast(.CT.accentDim, on: .CT.bg, atLeast: nonTextFloor, style: style, "accentDim on bg")
        }
    }

    // MARK: - Known gaps

    /// `danger` is 4.51 on the dark background and **3.95 on the light one** — below the text
    /// floor in light mode. It is the brand's destructive red and changing it is a separate
    /// decision, so it is recorded here rather than silently asserted away.
    ///
    /// This test fails in both directions on purpose: if the light value drops further, and also
    /// if someone fixes it without deleting this test. A known gap that no longer exists is a
    /// comment that has started lying.
    func testDangerIsBelowTheTextFloorInLightModeOnly() {
        assertContrast(.CT.danger, on: .CT.bg, atLeast: textFloor, style: .dark, "danger on bg (dark)")

        let light = ratio(.CT.danger, on: .CT.bg, style: .light)
        XCTAssertLessThan(light, textFloor,
                          "danger now clears the text floor in light mode — delete this test and add the pair to the asserted set")
        XCTAssertGreaterThanOrEqual(light, nonTextFloor,
                                    "danger in light mode fell below even the icon floor: \(light)")
    }

    // MARK: - Helpers

    private func assertContrast(
        _ fg: Color,
        on bg: Color,
        atLeast floor: Double,
        style: UIUserInterfaceStyle,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let value = ratio(fg, on: bg, style: style)
        let theme = style == .dark ? "dark" : "light"
        XCTAssertGreaterThanOrEqual(
            value, floor,
            String(format: "%@ [%@] is %.2f:1, needs %.2f:1", what, theme, value, floor),
            file: file, line: line
        )
    }

    private func ratio(_ fg: Color, on bg: Color, style: UIUserInterfaceStyle) -> Double {
        let l1 = luminance(of: fg, style: style)
        let l2 = luminance(of: bg, style: style)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    private func luminance(of color: Color, style: UIUserInterfaceStyle) -> Double {
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        func channel(_ c: CGFloat) -> Double {
            let v = Double(c)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }
}
#endif
