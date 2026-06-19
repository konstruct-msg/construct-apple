//
//  DuressPinSetupView.swift
//  Construct Messenger
//
//  Duress PIN setup flow: enter → confirm → done.
//  Validates that the duress PIN differs from the main PIN.
//

import SwiftUI

struct DuressPinSetupView: View {
    @Environment(SecurityViewModel.self) private var securityViewModel
    @Environment(\.dismiss) private var dismiss

    private enum Step { case enter, confirm }

    @State private var step: Step = .enter
    @State private var newPin = ""
    @State private var confirmPin = ""
    @State private var errorKey: String?
    @State private var shake = false

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

                Button {
                    handlePrimary()
                } label: {
                    Text("continue")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(canProceed ? Color.red.opacity(0.85) : Color.gray.opacity(0.4))
                        .cornerRadius(12)
                }
                .disabled(!canProceed)
                .padding(.horizontal, 32)
                .padding(.bottom, 16)
            }
            .navigationTitle(LocalizedStringKey(step == .enter ? "create_duress_pin" : "confirm_duress_pin"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }
                }
            }
            .onAppear {
                // Safety guard: duress PIN requires main PIN to be active
                if !securityViewModel.isPinEnabled { dismiss() }
            }
        }
    }

    // Duress PIN must be exactly the same length as the main PIN so that
    // PinLockView (which stops input at pinLength) can accept it.
    private var pinLength: Int { securityViewModel.pinLength ?? 6 }

    private var canProceed: Bool {
        switch step {
        case .enter:   return newPin.count == pinLength
        case .confirm: return confirmPin.count == pinLength
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .enter:
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(CTFont.regular(44))
                    .foregroundColor(Color.CT.danger)
                    .lineLimit(1).fixedSize()

                Text("duress_pin_setup_warning")
                    .font(CTFont.regular(13))
                    .foregroundColor(Color.CT.textDim)
                    .multilineTextAlignment(.center)

                PinDotsField(length: pinLength, pin: $newPin, shake: $shake) { _ in
                    handlePrimary()
                }
            }

        case .confirm:
            VStack(spacing: 20) {
                Text("confirm_duress_pin")
                    .font(.headline)

                PinDotsField(
                    length: newPin.count,
                    pin: $confirmPin,
                    shake: $shake
                ) { _ in
                    handlePrimary()
                }
            }
        }
    }

    private func handlePrimary() {
        errorKey = nil

        switch step {
        case .enter:
            guard newPin.count >= 4 else {
                errorKey = "pin_code_length"
                return
            }
            guard !securityViewModel.isDuressPinSameAsMain(newPin) else {
                errorKey = "duress_pin_matches_main"
                newPin = ""
                shake = true
                return
            }
            withAnimation { step = .confirm }

        case .confirm:
            guard newPin == confirmPin else {
                errorKey = "pin_codes_dont_match"
                confirmPin = ""
                shake = true
                return
            }
            let saved = securityViewModel.setDuressPin(newPin)
            if saved {
                dismiss()
            } else {
                // Race condition: main PIN changed between steps
                errorKey = "duress_pin_matches_main"
                newPin = ""
                confirmPin = ""
                step = .enter
            }
        }
    }
}

#if DEBUG
#Preview {
    DuressPinSetupView()
        .environment(SecurityViewModel())
}
#endif
