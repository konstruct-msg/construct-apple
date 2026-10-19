//
//  ScriptLanguage.swift
//  Construct Messenger
//
//  The language a piece of text is set in, when its script alone says which.
//
//  Han characters are shared by Japanese, Chinese and Korean, and several of them are drawn
//  differently in each (直, 骨, 角). Neither JetBrains Mono nor the system face has them, so the
//  OS falls back by the device's language list: with no Japanese in it, Japanese text gets
//  PingFang SC — Chinese forms — and with Korean before it, Korean ones (measured with CoreText,
//  2026-10-19, `client/shared/scripts-typefaces-and-brand-name.md` in the vault). Tagging the
//  text with its language makes the fallback the Japanese font, drawn by Japanese designers.
//
//  Only a script that belongs to one language decides: kana is Japanese, Hangul is Korean.
//  Han alone decides nothing — "了解" is both Japanese and Chinese, and guessing would turn the
//  same defect on Chinese text. That case keeps the device's choice, as before.
//

import SwiftUI

enum ScriptLanguage {
    static let japanese = Locale.Language(identifier: "ja")
    static let korean = Locale.Language(identifier: "ko")

    /// Japanese if `text` has kana, else Korean if it has Hangul, else nil.
    static func of(_ text: String) -> Locale.Language? {
        var hasHangul = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3041...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D:   // kana, small kana, half-width kana
                return japanese
            case 0x1100...0x11FF, 0x3131...0x318E, 0xAC00...0xD7A3:   // jamo, compatibility jamo, syllables
                hasHangul = true
            default:
                continue
            }
        }
        return hasHangul ? korean : nil
    }
}

extension View {
    /// Typesets this view in the language `text`'s script names (see `ScriptLanguage`), and
    /// leaves the device's choice alone when it names none.
    func typesetting(asScriptOf text: String) -> some View {
        let language = ScriptLanguage.of(text)
        return typesettingLanguage(language ?? ScriptLanguage.japanese, isEnabled: language != nil)
    }
}
