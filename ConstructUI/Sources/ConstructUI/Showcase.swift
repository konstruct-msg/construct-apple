//
//  Showcase.swift
//  ConstructUI
//
//  Design-system preview surface. Lives in a package with no WebRTC/WhisperKit
//  dependency, so Xcode Previews run here without the XOJIT _objc_fatal crash
//  that the main app target hits. Open ConstructUI/Package.swift in Xcode and
//  use the canvas below to iterate on CT tokens / components.
//

import SwiftUI

struct CTShowcaseView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("> CONSTRUCT UI")
                    .font(CTFont.bold(18))
                    .foregroundStyle(Color.CT.accent)

                colorSwatches
                typographySamples
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.CT.bg)
    }

    private var colorSwatches: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("colors").font(CTFont.regular(12)).foregroundStyle(Color.CT.textDim)
            HStack(spacing: 12) {
                swatch("bg", Color.CT.bg)
                swatch("text", Color.CT.text)
                swatch("accent", Color.CT.accent)
                swatch("danger", Color.CT.danger)
                swatch("noise", Color.CT.noise)
                swatch("dim", Color.CT.textDim)
            }
        }
    }

    private func swatch(_ name: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 6)
                .fill(color)
                .frame(width: 44, height: 44)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.CT.noise, lineWidth: 1))
            Text(name).font(CTFont.regular(10)).foregroundStyle(Color.CT.textDim)
        }
    }

    private var typographySamples: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("typography").font(CTFont.regular(12)).foregroundStyle(Color.CT.textDim)
            Text("JetBrains Mono · regular 16").font(CTFont.regular(16)).foregroundStyle(Color.CT.text)
            Text("JetBrains Mono · bold 16").font(CTFont.bold(16)).foregroundStyle(Color.CT.text)
        }
    }
}

#Preview("CT Showcase") {
    CTShowcaseView()
}
