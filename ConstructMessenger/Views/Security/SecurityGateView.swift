//
//  SecurityGateView.swift
//  Construct Messenger
//
//  Created by Codex on 06.02.2026.
//

import SwiftUI

struct SecurityGateView<Content: View>: View {
    @Environment(SecurityViewModel.self) private var securityViewModel
    @Environment(\.scenePhase) private var scenePhase

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            content
                .disabled(securityViewModel.requiresUnlock)
                .blur(radius: securityViewModel.requiresUnlock ? 8 : 0)

            if securityViewModel.requiresUnlock {
                PinLockView()
                    .transition(.opacity)
            }
        }
        .onAppear {
            securityViewModel.refreshPinState()
            securityViewModel.refreshBiometricAvailability()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background, .inactive:
                securityViewModel.lockIfNeeded()
            case .active:
                securityViewModel.refreshBiometricAvailability()
            @unknown default:
                break
            }
        }
    }
}

#Preview {
    SecurityGateView {
        Text("Preview")
    }
    .environment(SecurityViewModel())
}
