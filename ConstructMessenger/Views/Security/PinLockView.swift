//
//  PinLockView.swift
//  Construct Messenger
//
//  Lock screen: lattice background, logo, iOS-style round-key numpad.
//  Biometric mode auto-triggers Face ID / Touch ID on appear.
//  PIN mode shows dot indicator + custom numpad (no system keyboard).
//
//  Escape hatch: "can't sign in?" → confirm → 10s countdown → local reset.
//  A PIN is NEVER reset in place to re-enter the same account; the only way out
//  of the lock without the PIN is a deliberate destructive local reset that drops
//  to onboarding (identity recoverable via seed phrase if recovery was configured).
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

struct PinLockView: View {
    @Environment(SecurityViewModel.self) private var securityViewModel
    @Environment(AuthViewModel.self) private var authViewModel

    @State private var pin = ""
    @State private var errorMessage: String?
    @State private var showPinEntry = false
    @State private var didAttemptBiometrics = false
    @State private var shakeOffset: CGFloat = 0

    // Escape hatch (local reset) state
    @State private var showResetConfirm = false
    @State private var resetCountdown: Int?
    @State private var resetTimer: Timer?

    private static let resetCountdownSeconds = 10
    private let keySize: CGFloat = 74

    var body: some View {
        ZStack {
            Color.CT.bg.ignoresSafeArea()
            CTMatrixBackground().ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                CTLogoView(size: 140)

                Spacer().frame(height: 44)

                if showPinEntry || !isBiometricMode {
                    pinEntryContent
                } else {
                    biometricContent
                }

                Spacer()

                if showPinEntry || !isBiometricMode {
                    escapeHatch
                        .padding(.bottom, 24)
                        .animation(.easeInOut(duration: 0.2), value: resetCountdown)
                }
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
        .onDisappear { cancelResetTimer() }
        .alert(NSLocalizedString("pin_reset_title", comment: ""), isPresented: $showResetConfirm) {
            Button(NSLocalizedString("pin_reset_action", comment: ""), role: .destructive) {
                startResetCountdown()
            }
            Button(NSLocalizedString("cancel", comment: ""), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("pin_reset_explain", comment: ""))
        }
    }

    // MARK: - Biometric UI

    private var biometricContent: some View {
        VStack(spacing: 20) {
            Image(systemName: securityViewModel.biometricIconName)
                .font(.system(size: 64))
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

            Button(NSLocalizedString("use_pin_code", comment: "")) {
                withAnimation { showPinEntry = true; errorMessage = nil }
            }
            .font(CTFont.regular(14))
            .foregroundStyle(Color.CT.accent)
            .padding(.top, 8)
        }
    }

    // MARK: - PIN Entry UI

    private var pinEntryContent: some View {
        VStack(spacing: 40) {
            dotsIndicator

            numpad

            Text(errorMessage ?? " ")
                .foregroundStyle(Color.CT.danger)
                .font(CTFont.regular(13))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .frame(height: 18)
                .opacity(errorMessage == nil ? 0 : 1)
        }
    }

    // MARK: - Escape hatch (local reset)

    @ViewBuilder
    private var escapeHatch: some View {
        if let secs = resetCountdown {
            VStack(spacing: 10) {
                Text(String(format: NSLocalizedString("pin_reset_countdown", comment: ""), secs))
                    .font(CTFont.medium(14))
                    .foregroundStyle(Color.CT.danger)
                    .contentTransition(.numericText())
                Button(NSLocalizedString("cancel", comment: "")) { cancelResetTimer() }
                    .font(CTFont.regular(13))
                    .foregroundStyle(Color.CT.accent)
            }
            .transition(.opacity)
        } else {
            Button { showResetConfirm = true } label: {
                Text(NSLocalizedString("cant_unlock", comment: ""))
                    .font(CTFont.regular(13))
                    .foregroundStyle(Color.CT.textDim)
                    .underline()
            }
            .transition(.opacity)
        }
    }

    // MARK: - Dot Indicator

    private var dotsIndicator: some View {
        let length = expectedPinLength ?? 6
        return HStack(spacing: 16) {
            ForEach(0 ..< length, id: \.self) { index in
                Circle()
                    .fill(index < pin.count ? Color.CT.text : Color.clear)
                    .overlay(
                        Circle().stroke(
                            Color.CT.text.opacity(index < pin.count ? 1.0 : 0.3),
                            lineWidth: 1.5
                        )
                    )
                    .frame(width: 13, height: 13)
                    .scaleEffect(index == pin.count - 1 && pin.count > 0 ? 1.2 : 1.0)
                    .animation(.spring(response: 0.2, dampingFraction: 0.5), value: pin.count)
            }
        }
        .offset(x: shakeOffset)
    }

    // MARK: - Custom Numpad

    // "bio" → biometric quick-trigger (or empty), "del" → backspace. Both interactive
    // → SF Symbols per design system. Digits stay JetBrains Mono.
    private static let numpadRows: [[String]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["bio", "0", "del"]
    ]

    private var numpad: some View {
        VStack(spacing: 16) {
            ForEach(Self.numpadRows, id: \.self) { row in
                HStack(spacing: 24) {
                    ForEach(row, id: \.self) { key in
                        keypadKey(key)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func keypadKey(_ key: String) -> some View {
        switch key {
        case "bio":
            if isBiometricMode {
                Button {
                    pin = ""
                    errorMessage = nil
                    authenticateWithBiometrics()
                } label: {
                    Image(systemName: securityViewModel.biometricIconName)
                        .font(.system(size: 26))
                        .foregroundStyle(Color.CT.accent)
                        .frame(width: keySize, height: keySize)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: keySize, height: keySize)
            }
        case "del":
            Button {
                tapHaptic()
                if !pin.isEmpty { pin.removeLast() }
            } label: {
                Image(systemName: "delete.left")
                    .font(.system(size: 24))
                    .foregroundStyle(pin.isEmpty ? Color.CT.textDim.opacity(0.4) : Color.CT.text)
                    .frame(width: keySize, height: keySize)
            }
            .buttonStyle(.plain)
            .disabled(pin.isEmpty)
        default:
            Button { numpadTap(key) } label: {
                Text(key)
                    .font(CTFont.regular(30))
                    .foregroundStyle(Color.CT.text)
                    .frame(width: keySize, height: keySize)
            }
            .buttonStyle(KeypadButtonStyle())
        }
    }

    // MARK: - Logic

    private func numpadTap(_ key: String) {
        let length = expectedPinLength ?? 6
        guard pin.count < length else { return }
        tapHaptic()
        pin.append(key)
        if pin.count == length { handlePinInput() }
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
                cancelResetTimer()
                securityViewModel.isUnlocked = true
            } else if let message {
                self.errorMessage = message
            }
        }
    }

    private func handlePinInput() {
        errorMessage = nil
        if securityViewModel.verifyPin(pin) {
            cancelResetTimer()
            securityViewModel.isUnlocked = true
            return
        }
        if securityViewModel.verifyDuressPin(pin) {
            // Silent wipe — no error, no shake, just disappear as if unlocked.
            cancelResetTimer()
            authViewModel.triggerDuressWipe()
            return
        }
        errorMessage = NSLocalizedString("wrong_pin_code", comment: "")
        pin = ""
        errorHaptic()
        triggerShake()
    }

    // MARK: - Local reset countdown

    private func startResetCountdown() {
        cancelResetTimer()
        resetCountdown = Self.resetCountdownSeconds
        resetTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in tickReset() }
        }
    }

    @MainActor
    private func tickReset() {
        guard let current = resetCountdown else { return }
        if current <= 1 {
            performLocalReset()
        } else {
            withAnimation { resetCountdown = current - 1 }
        }
    }

    private func cancelResetTimer() {
        resetTimer?.invalidate()
        resetTimer = nil
        resetCountdown = nil
    }

    /// Destructive local reset. Wipes PIN/biometric state and all local crypto
    /// (device keys, OTPKs, Kyber SPK) so `requiresUnlock` and `isAuthenticated`
    /// both fall false — SecurityGateView removes this view and ContentView routes
    /// to OnboardingView. Identity returns only via seed phrase recovery.
    private func performLocalReset() {
        cancelResetTimer()
        securityViewModel.wipeSecurityState()
        authViewModel.wipeAndReregister()
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

    private func tapHaptic() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    private func errorHaptic() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        #endif
    }
}

// MARK: - Keypad button style

/// iOS-passcode-style round key with CT tokens: noise fill, accent press flash,
/// subtle hairline ring, spring scale on press.
private struct KeypadButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Circle().fill(
                    configuration.isPressed
                        ? Color.CT.accent.opacity(0.25)
                        : Color.CT.noise.opacity(0.6)
                )
            )
            .overlay(
                Circle().stroke(Color.CT.text.opacity(0.08), lineWidth: 1)
            )
            .clipShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.spring(response: 0.18, dampingFraction: 0.6), value: configuration.isPressed)
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
