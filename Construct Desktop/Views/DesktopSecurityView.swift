//
//  DesktopSecurityView.swift
//  Construct Desktop
//
//  Minimal macOS-friendly security settings.
//

import SwiftUI

struct DesktopSecurityView: View {
    @Environment(SecurityViewModel.self) private var securityViewModel

    var body: some View {
        @Bindable var securityViewModel = securityViewModel
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("App PIN")
                Spacer()
                Text(securityViewModel.isPinEnabled ? "Enabled" : "Disabled")
                    .foregroundStyle(securityViewModel.isPinEnabled ? .green : .secondary)
            }

            if securityViewModel.isPinEnabled {
                Toggle("Use Biometrics", isOn: $securityViewModel.isBiometricEnabled)
                    .disabled(!securityViewModel.isBiometricAvailable)
            }

            Text("PIN setup and advanced security actions are currently managed in the iOS app.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { securityViewModel.refreshPinState() }
    }
}
