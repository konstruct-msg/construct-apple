//
//  ScriptLanguageTests.swift
//  ConstructMessengerTests
//
//  Japanese text takes Japanese forms of the Han characters it shares with Chinese, whatever the
//  device's languages are. The rule is `ScriptLanguage.of`; the rendering tests prove the tag
//  reaches the font fallback rather than trusting that it does.
//

import SwiftUI
import XCTest
@testable import Construct_Messenger

final class ScriptLanguageTests: XCTestCase {

    func testKanaIsJapanese() {
        XCTAssertEqual(ScriptLanguage.of("直してください"), ScriptLanguage.japanese)
        XCTAssertEqual(ScriptLanguage.of("カメラ"), ScriptLanguage.japanese)
        XCTAssertEqual(ScriptLanguage.of("ｶﾒﾗ"), ScriptLanguage.japanese, "half-width katakana")
        XCTAssertEqual(ScriptLanguage.of("see 骨 and ね"), ScriptLanguage.japanese)
    }

    func testHangulIsKorean() {
        XCTAssertEqual(ScriptLanguage.of("한국어 漢字"), ScriptLanguage.korean)
    }

    /// Mixed kana and Hangul: kana decides, wherever it stands.
    func testKanaOutranksHangul() {
        XCTAssertEqual(ScriptLanguage.of("한국 と 日本"), ScriptLanguage.japanese)
    }

    /// Han alone could be Chinese; tagging it Japanese would move the defect, not fix it.
    func testHanAloneAndOtherScriptsNameNothing() {
        XCTAssertNil(ScriptLanguage.of("了解"))
        XCTAssertNil(ScriptLanguage.of("直骨角"))
        XCTAssertNil(ScriptLanguage.of("hello, привет, Բարև"))
        XCTAssertNil(ScriptLanguage.of("「」、。"), "CJK punctuation is shared")
        XCTAssertNil(ScriptLanguage.of(""))
    }

    // MARK: - Rendering

    private static let sample = "直骨角です"

    @MainActor
    private func png<V: View>(_ view: V) throws -> Data {
        let renderer = ImageRenderer(content: view.font(.system(size: 40)).foregroundStyle(.black).padding(4).background(.white))
        renderer.scale = 2
        #if canImport(UIKit)
        return try XCTUnwrap(renderer.uiImage?.pngData())
        #else
        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        return try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        #endif
    }

    /// The premise: the tag changes the drawn glyphs. Without this the next test could pass on a
    /// device where Japanese and Chinese happen to fall back to the same font.
    @MainActor
    func testTheLanguageTagChangesTheHanForms() throws {
        let ja = try png(Text(Self.sample).typesettingLanguage(ScriptLanguage.japanese))
        let zh = try png(Text(Self.sample).typesettingLanguage(Locale.Language(identifier: "zh-Hans")))
        XCTAssertNotEqual(ja, zh)
    }

    /// A message bubble sets Japanese text in Japanese forms even where everything around it says
    /// Chinese. Mutation: drop `.typesetting(asScriptOf:)` from `LinkDetectingText` — the outer
    /// zh-Hans tag then reaches the text and the two renderings differ.
    @MainActor
    func testABubbleSetsJapaneseTextInJapaneseForms() throws {
        let inChinese = try png(LinkDetectingText(Self.sample, color: .black)
            .typesettingLanguage(Locale.Language(identifier: "zh-Hans")))
        let inJapanese = try png(LinkDetectingText(Self.sample, color: .black)
            .typesettingLanguage(ScriptLanguage.japanese))
        XCTAssertEqual(inChinese, inJapanese)
    }
}
