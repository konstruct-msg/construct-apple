//
//  PinLockView.swift
//  Construct Messenger
//
//  Created by Codex on 06.02.2026.
//

import SwiftUI

struct PinLockView: View {
    @EnvironmentObject var securityViewModel: SecurityViewModel

    @State private var pin = ""
    @State private var errorMessage: String?
    @State private var showPinEntry = false
    @State private var didAttemptBiometrics = false
    @State private var shake = false

    var body: some View {
        ZStack {
            Color.AppBackground.primary
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()
                
                Image("KonstructLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 120, height: 120)
                
                Spacer()

                if showPinEntry || !isBiometricMode {
                    VStack(spacing: 16) {
                        Text("enter_pin_code")
                            .font(.headline)

                        PinDotsField(
                            length: expectedPinLength ?? 6,
                            pin: $pin,
                            shake: $shake
                        ) { _ in
                            handlePinInput()
                        }
                    }
                    .padding(.horizontal, 32)
                    
                    if isBiometricMode {
                        Button {
                            pin = ""
                            errorMessage = nil
                            authenticateWithBiometrics()
                        } label: {
                            Label(
                                String(format: NSLocalizedString("use_biometric", comment: ""), securityViewModel.biometricDisplayName),
                                systemImage: securityViewModel.biometricIconName
                            )
                        }
                        .padding(.top, 4)
                    }
                } else {
                    Button {
                        authenticateWithBiometrics()
                    } label: {
                        Label(
                            String(format: NSLocalizedString("use_biometric", comment: ""), securityViewModel.biometricDisplayName),
                            systemImage: securityViewModel.biometricIconName
                        )
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal, 32)

                    Button("use_pin_code") {
                        withAnimation {
                            showPinEntry = true
                            errorMessage = nil
                        }
                    }
                    .padding(.top, 4)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Spacer()
            }
        }
        .onAppear {
            if isBiometricMode {
                showPinEntry = false
                authenticateIfNeeded()
            } else {
                showPinEntry = true
            }
        }
    }

    private var isBiometricMode: Bool {
        securityViewModel.isBiometricEnabled && securityViewModel.isBiometricAvailable
    }

    private var expectedPinLength: Int? {
        securityViewModel.pinLength
    }

    private func authenticateIfNeeded() {
        guard !didAttemptBiometrics else { return }
        didAttemptBiometrics = true
        authenticateWithBiometrics()
    }

    private func authenticateWithBiometrics() {
        errorMessage = nil
        securityViewModel.authenticateWithBiometrics(reason: NSLocalizedString("unlock", comment: "")) { success, errorMessage in
            if success {
                securityViewModel.isUnlocked = true
            } else if let errorMessage {
                self.errorMessage = errorMessage
            } else {
                self.errorMessage = NSLocalizedString("wrong_pin_code", comment: "")
            }
        }
    }

    private func unlockWithPin() {
        errorMessage = nil
        if securityViewModel.verifyPin(pin) {
            securityViewModel.isUnlocked = true
        } else {
            errorMessage = NSLocalizedString("wrong_pin_code", comment: "")
        }
    }

    private func handlePinInput() {
        errorMessage = nil

        if securityViewModel.verifyPin(pin) {
            securityViewModel.isUnlocked = true
            return
        }

        // Wrong PIN
        errorMessage = NSLocalizedString("wrong_pin_code", comment: "")
        pin = ""
        shake = true
    }

}

#Preview {
    PinLockView()
        .environmentObject(SecurityViewModel())
}
