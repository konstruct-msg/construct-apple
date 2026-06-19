//
//  Support.swift
//  ConstructUI
//
//  Pieces ConstructTheme depends on, extracted from the app (UIConstants.swift,
//  MainAvatarView.swift) so the design system is self-contained in this package.
//  Keep in sync if the app definitions change.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
/// Cross-platform image type. Mirrors the app's `PlatformImage` typealias so
/// image-bearing components (avatars, crops) compile here without UIKit/AppKit
/// branching at every call site.
public typealias PlatformImage = UIImage
#else
import AppKit
public typealias PlatformImage = NSImage
#endif

struct ConstructFont {
    /// User-controlled text scale (from Settings/Appearance).
    /// compact=0.9, standard=1.0, large=1.15
    static var textScale: CGFloat {
        let pref = UserDefaults.standard.string(forKey: "textSize") ?? "standard"
        switch pref {
        case "compact": return 0.9
        case "large": return 1.15
        default: return 1.0
        }
    }

    /// Monospace — timestamps, fingerprints, status labels, crypto badges.
    /// Target: JetBrains Mono (supports Cyrillic). Fallback: system monospaced.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let scaled = size * textScale
        if let _ = fontExists("JetBrainsMono-Regular") {
            let name: String
            switch weight {
            case .medium:  name = "JetBrainsMono-Medium"
            case .bold:    name = "JetBrainsMono-Bold"
            default:       name = "JetBrainsMono-Regular"
            }
            return .custom(name, size: scaled)
        }
        return .system(size: scaled, weight: weight, design: .monospaced)
    }

    /// Display — contact names, headers, buttons.
    static func display(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        let scaled = size * textScale
        if let _ = fontExists("Exo2-Medium") {
            let name: String
            switch weight {
            case .semibold: name = "Exo2-SemiBold"
            case .bold:     name = "Exo2-Bold"
            case .light:    name = "Exo2-Light"
            default:        name = "Exo2-Medium"
            }
            return .custom(name, size: scaled)
        }
        return .system(size: scaled, weight: weight, design: .rounded)
    }

    private static func fontExists(_ name: String) -> String? {
        #if canImport(UIKit)
        return UIFont(name: name, size: 12) != nil ? name : nil
        #else
        return NSFont(name: name, size: 12) != nil ? name : nil
        #endif
    }
}

extension Color {
    /// Derives a consistent accent color from a user ID (or any stable string).
    /// hsl(hash(id) % 360, 60%, 55%) — must match the app + Android (djb2/UInt32).
    static func hexagonAccent(for id: String) -> Color {
        var hash: UInt32 = 5381
        for scalar in id.unicodeScalars {
            hash = (hash &<< 5) &+ hash &+ scalar.value
        }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.60, brightness: 0.55)
    }
}
