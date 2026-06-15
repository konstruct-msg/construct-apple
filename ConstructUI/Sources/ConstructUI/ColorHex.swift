//
//  ColorHex.swift
//  ConstructUI
//
//  Extracted from the app's UIConstants.swift so ConstructTheme is self-contained
//  inside this package. Keep in sync if the app's definition changes.
//

import SwiftUI

extension Color {
    /// Initialise from a 24-bit RGB hex literal, e.g. `Color(hex: 0xff5500)`.
    init(hex: UInt32) {
        self.init(
            red:   Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >>  8) & 0xff) / 255,
            blue:  Double( hex        & 0xff) / 255
        )
    }
}
