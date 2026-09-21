//
//  ThemeTypographyTests.swift
//  ConstructMessengerTests
//
//  The chrome is JetBrains Mono, and for eight months it was not: the name was looked up, no
//  file was bundled, and SF Mono rendered in its place with nothing to say so. Then the first
//  bundling attempt registered the faces under `Fonts/…` while the synchronized group flattens
//  resources into the bundle root — a path iOS ignores, silently, in the same way. This is the
//  check that would have failed both times.
//

import SwiftUI
import XCTest
@testable import Construct_Messenger

#if canImport(UIKit)
final class ThemeTypographyTests: XCTestCase {

    /// Every face `ConstructFont.mono` can name must resolve in the running app, or the
    /// weight silently degrades to the fallback.
    func testEveryBundledWeightResolvesByPostScriptName() {
        for name in ["JetBrainsMono-Regular", "JetBrainsMono-Medium",
                     "JetBrainsMono-SemiBold", "JetBrainsMono-Bold"] {
            XCTAssertNotNil(UIFont(name: name, size: 12), "\(name) is not registered — check UIAppFonts against the bundle root")
        }
    }

    /// The family is registered under the name the code looks up, not merely present as a file.
    func testFamilyNameIsTheOneTheThemeExpects() {
        let font = UIFont(name: "JetBrainsMono-Regular", size: 12)
        XCTAssertEqual(font?.familyName, "JetBrains Mono")
    }

    /// Message text defaults to the system face; the chrome does not read this preference.
    func testMessageFaceDefaultsToSystemWhenNothingIsStored() {
        let key = ChatTextPreference.faceKey
        let saved = UserDefaults.standard.string(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(ChatTextPreference.face, .system)
        XCTAssertEqual(ChatTextPreference.Face.allCases.first, ChatTextPreference.defaultFace,
                       "the picker lists the default first")
    }
}
#endif
