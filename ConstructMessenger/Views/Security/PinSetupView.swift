//
//  PinSetupView.swift
//  Construct Messenger
//
//  Created by Codex on 06.02.2026.
//

import SwiftUI

struct PinSetupView: View {
    @EnvironmentObject var securityViewModel: SecurityViewModel
    @Environment(\.dismiss) private var dismiss

    private enum Step {
        case currentPin
        case enterPin
        case confirmPin
        case biometric
    }

    @State private var step: Step
    @State private var currentPin = ""
    @State private var newPin = ""
    @State private var confirmPin = ""
    @State private var errorKey: String?
    @State private var enableBiometrics = false
    @State private var shake = false

    private let isChanging: Bool

    init(isChanging: Bool) {
        self.isChanging = isChanging
        _step = State(initialValue: isChanging ? .currentPin : .enterPin)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()

                content
                    .padding(.horizontal, 32)

                if let errorKey {
                    Text(LocalizedStringKey(errorKey))
                        .foregroundColor(.red)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .padding(.top, 12)
                        .padding(.horizontal, 32)
                }

                Spacer()

                // Bottom action button (above keyboard)
                if step != .biometric || !securityViewModel.isBiometricAvailable {
                    Button {
                        handlePrimaryAction()
                    } label: {
                        Text(primaryActionTitle)
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(canProceed ? Color.AppBrand.second : Color.gray.opacity(0.4))
                            .cornerRadius(12)
                    }
                    .disabled(!canProceed)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 16)
                }
            }
            .navigationTitle(titleKey)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var titleKey: LocalizedStringKey {
        switch step {
        case .currentPin:
            return "enter_pin_code"
        case .enterPin:
            return "create_pin_code"
        case .confirmPin:
            return "confirm_pin_code"
        case .biometric:
            return "security"
        }
    }

    private var primaryActionTitle: LocalizedStringKey {
        switch step {
        case .biometric:
            return "done"
        default:
            return "continue"
        }
    }

    private var canProceed: Bool {
        switch step {
        case .currentPin:
            return currentPin.count >= 6
        case .enterPin:
            return newPin.count >= 6
        case .confirmPin:
            return confirmPin.count >= 6
        case .biometric:
            return true
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .currentPin:
            VStack(spacing: 16) {
                Text("enter_pin_code")
                    .font(.headline)
                PinDotsField(
                    length: securityViewModel.pinLength ?? 6,
                    pin: $currentPin,
                    shake: $shake
                ) { _ in
                    handlePrimaryAction()
                }
            }
        case .enterPin:
            VStack(spacing: 16) {
                Text("create_pin_code")
                    .font(.headline)
                PinDotsField(length: 6, pin: $newPin, shake: $shake)
                Text("pin_code_length")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .confirmPin:
            VStack(spacing: 16) {
                Text("confirm_pin_code")
                    .font(.headline)
                PinDotsField(
                    length: newPin.count,
                    pin: $confirmPin,
                    shake: $shake
                ) { _ in
                    handlePrimaryAction()
                }
            }
        case .biometric:
            VStack(spacing: 16) {
                if securityViewModel.isBiometricAvailable {
                    let label = String(format: NSLocalizedString("enable_biometric", comment: ""), securityViewModel.biometricDisplayName)
                    Text(label)
                        .font(.headline)
                        .multilineTextAlignment(.center)

                    Toggle(isOn: $enableBiometrics) {
                        Text(String(format: NSLocalizedString("use_biometric", comment: ""), securityViewModel.biometricDisplayName))
                    }
                    .toggleStyle(.switch)

                    Button {
                        securityViewModel.setPin(newPin)
                        securityViewModel.isBiometricEnabled = enableBiometrics
                        dismiss()
                    } label: {
                        Text("done")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.AppBrand.second)
                            .cornerRadius(12)
                    }
                    .padding(.top, 8)
                } else {
                    Text("biometric_unavailable")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    private func handlePrimaryAction() {
        errorKey = nil

        switch step {
        case .currentPin:
            guard securityViewModel.verifyPin(currentPin) else {
                errorKey = "wrong_pin_code"
                currentPin = ""
                shake = true
                return
            }
            withAnimation { step = .enterPin }
        case .enterPin:
            guard newPin.count >= 6 else {
                errorKey = "pin_code_length"
                return
            }
            withAnimation { step = .confirmPin }
        case .confirmPin:
            guard newPin == confirmPin else {
                errorKey = "pin_codes_dont_match"
                confirmPin = ""
                shake = true
                return
            }
            if securityViewModel.isBiometricAvailable {
                withAnimation { step = .biometric }
            } else {
                securityViewModel.setPin(newPin)
                dismiss()
            }
        case .biometric:
            securityViewModel.setPin(newPin)
            securityViewModel.isBiometricEnabled = enableBiometrics
            dismiss()
        }
    }
}

#Preview {
    PinSetupView(isChanging: false)
        .environmentObject(SecurityViewModel())
}
