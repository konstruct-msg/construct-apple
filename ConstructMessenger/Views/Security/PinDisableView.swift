//
//  PinDisableView.swift
//  Construct Messenger
//
//  Created by Codex on 06.02.2026.
//

import SwiftUI

struct PinDisableView: View {
    @EnvironmentObject var securityViewModel: SecurityViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var pin = ""
    @State private var errorKey: String?
    @State private var shake = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 16) {
                    Text("enter_pin_code")
                        .font(.headline)

                    PinDotsField(
                        length: securityViewModel.pinLength ?? 6,
                        pin: $pin,
                        shake: $shake
                    ) { _ in
                        disablePin()
                    }

                    if let errorKey {
                        Text(LocalizedStringKey(errorKey))
                            .foregroundColor(.red)
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 32)

                Spacer()

                Button {
                    disablePin()
                } label: {
                    Text("disable")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(pin.count >= 6 ? Color.red : Color.gray.opacity(0.4))
                        .cornerRadius(12)
                }
                .disabled(pin.count < 6)
                .padding(.horizontal, 32)
                .padding(.bottom, 16)
            }
            .navigationTitle("disable_pin_code")
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

    private func disablePin() {
        errorKey = nil
        if securityViewModel.verifyPin(pin) {
            securityViewModel.disablePin()
            dismiss()
        } else {
            errorKey = "wrong_pin_code"
            pin = ""
            shake = true
        }
    }
}

#Preview {
    PinDisableView()
        .environmentObject(SecurityViewModel())
}
