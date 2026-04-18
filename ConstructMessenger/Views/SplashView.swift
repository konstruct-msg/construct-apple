//
//  SplashView.swift
//  Construct Messenger
//

import SwiftUI

/// Full-screen launch placeholder shown while auth state is being determined
/// (e.g. Keychain read in progress or device locked by biometrics).
struct SplashView: View {

    @State private var logoOpacity: Double = 0
    @State private var noiseOpacity: Double = 0

    var body: some View {
        ZStack {
            Color.CT.bg.ignoresSafeArea()

            CTNoise(rows: 48, cols: 24)
                .ignoresSafeArea()
                .opacity(noiseOpacity)

            CTLogoView(size: 72, color: Color.CT.accent)
                .opacity(logoOpacity)
        }
        .onAppear {
            withAnimation(.easeIn(duration: 0.5)) {
                noiseOpacity = 1
            }
            withAnimation(.easeIn(duration: 0.35)) {
                logoOpacity = 1
            }
        }
    }
}

#Preview {
    SplashView()
}
