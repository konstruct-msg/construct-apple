//
//  CTLogoView.swift
//  Construct Messenger
//

import SwiftUI

struct CTLogoView: View {

    /// Bounding square side-length in points.
    var size: CGFloat = 134
    /// Tint applied to the logo image (ignored when color can't tint PDF).
    var color: Color = Color.CT.accent

    var body: some View {
        Image("KonstructLogo")
            .resizable()
            .renderingMode(.template)
            .foregroundStyle(color)
            .scaledToFit()
            .frame(width: size, height: size)
    }
}
