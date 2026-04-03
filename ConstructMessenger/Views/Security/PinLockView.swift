//
//  PinLockView.swift
//  Construct Messenger
//
//  Lock screen: lattice background, logo, custom round-button numpad.
//  Biometric mode auto-triggers Face ID / Touch ID on appear.
//  PIN mode shows dot indicator + custom numpad (no system keyboard).
//

import SwiftUI

struct PinLockView: View {
    @Environment(SecurityViewModel.self) private var securityViewModel
    @Environment(AuthViewModel.self) private var authViewModel

    @State private var pin = ""
    @State private var errorMessage: String?
    @State private var showPinEntry = false
    @State private var didAttemptBiometrics = false
    @State private var shakeOffset: CGFloat = 0

    var body: some View {
        ZStack {
            Color.CT.bg.ignoresSafeArea()
            CTMatrixBackground().ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                CTLogoView(size: 134)

                Spacer().frame(height: 52)

                if showPinEntry || !isBiometricMode {
                    pinEntryContent
                } else {
                    biometricContent
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

    // MARK: - Biometric UI

    private var biometricContent: some View {
        VStack(spacing: 20) {
            Image(systemName: securityViewModel.biometricIconName)
                .font(.system(size: 52, weight: .thin))
                .foregroundStyle(Color.CT.accent)

            Text(String(format: NSLocalizedString("use_biometric", comment: ""),
                        securityViewModel.biometricDisplayName))
                .font(CTFont.medium(16))
                .foregroundStyle(Color.CT.textDim)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(Color.CT.danger)
                    .font(CTFont.regular(13))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Button("use_pin_code") {
                withAnimation { showPinEntry = true; errorMessage = nil }
            }
            .foregroundStyle(Color.CT.accent)
            .padding(.top, 8)
        }
    }

    // MARK: - PIN Entry UI

    private var pinEntryContent: some View {
        VStack(spacing: 36) {
            
            dotsIndicator
                .padding(24)
            
            numpad
                .padding(24)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(Color.CT.danger)
                    .font(CTFont.regular(13))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            if isBiometricMode {
                Button {
                    pin = ""
                    errorMessage = nil
                    authenticateWithBiometrics()
                } label: {
                    Label(
                        String(format: NSLocalizedString("use_biometric", comment: ""),
                               securityViewModel.biometricDisplayName),
                        systemImage: securityViewModel.biometricIconName
                    )
                    .foregroundStyle(Color.CT.accent)
                }
            }
        }
    }

    // MARK: - Dot Indicator

    private var dotsIndicator: some View {
        let length = expectedPinLength ?? 6
        return HStack(spacing: 14) {
            ForEach(0 ..< length, id: \.self) { index in
                Circle()
                    .fill(index < pin.count ? Color.CT.text : Color.clear)
                    .overlay(
                        Circle().stroke(
                            Color.CT.text.opacity(index < pin.count ? 1.0 : 0.3),
                            lineWidth: 1.5
                        )
                    )
                    .frame(width: 14, height: 14)
                    .scaleEffect(index == pin.count - 1 && pin.count > 0 ? 1.15 : 1.0)
                    .animation(.spring(response: 0.2, dampingFraction: 0.5), value: pin.count)
            }
        }
        .offset(x: shakeOffset)
    }

    // MARK: - Custom Numpad

    private static let numpadRows: [[String]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["",  "0", "⌫"]
    ]

    private var numpad: some View {
        VStack(spacing: 12) {
            ForEach(Self.numpadRows, id: \.self) { row in
                HStack(spacing: 18) {
                    ForEach(row, id: \.self) { key in
                        numpadButton(key)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func numpadButton(_ key: String) -> some View {
        if key.isEmpty {
            Color.clear.frame(width: 76, height: 76)
        } else {
            Button { numpadTap(key) } label: {
                ZStack {
                    Circle()
                        .fill(Color.CT.noise)
                    if key == "⌫" {
                        Image(systemName: "delete.left")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(Color.CT.text)
                    } else {
                        Text(key)
                            .font(CTFont.regular(26))
                            .foregroundStyle(Color.CT.text)
                    }
                }
                .frame(width: 76, height: 76)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Logic

    private func numpadTap(_ key: String) {
        let length = expectedPinLength ?? 6
        if key == "⌫" {
            if !pin.isEmpty { pin.removeLast() }
        } else {
            guard pin.count < length else { return }
            pin.append(key)
            if pin.count == length { handlePinInput() }
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
        securityViewModel.authenticateWithBiometrics(
            reason: NSLocalizedString("unlock", comment: "")
        ) { success, message in
            if success {
                securityViewModel.isUnlocked = true
            } else if let message {
                self.errorMessage = message
            }
        }
    }

    private func handlePinInput() {
        errorMessage = nil
        if securityViewModel.verifyPin(pin) {
            securityViewModel.isUnlocked = true
            return
        }
        if securityViewModel.verifyDuressPin(pin) {
            // Silent wipe — no error, no shake, just disappear as if unlocked
            authViewModel.triggerDuressWipe()
            return
        }
        errorMessage = NSLocalizedString("wrong_pin_code", comment: "")
        pin = ""
        triggerShake()
    }

    private func triggerShake() {
        let steps: [(CGFloat, Double)] = [(10, 0), (-8, 0.08), (6, 0.16), (-4, 0.24), (0, 0.32)]
        for (offset, delay) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.spring(response: 0.08, dampingFraction: 0.3)) {
                    shakeOffset = offset
                }
            }
        }
    }
}

#if DEBUG
#Preview("PIN entry") {
    let container = PreviewHelpers.createPreviewContainer()
    let authVM = AuthViewModel(context: container.viewContext)
    authVM.configureMockAuth()
    return PinLockView()
        .environment(SecurityViewModel())
        .environment(authVM)
}

#Preview("Biometric") {
    let container = PreviewHelpers.createPreviewContainer()
    let authVM = AuthViewModel(context: container.viewContext)
    authVM.configureMockAuth()
    let vm = SecurityViewModel()
    vm.isBiometricAvailable = true
    vm.isBiometricEnabled = true
    return PinLockView()
        .environment(vm)
        .environment(authVM)
}
#endif
