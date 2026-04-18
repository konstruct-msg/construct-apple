//
//  OnboardingView.swift
//  Construct Messenger
//
//  Passwordless onboarding with optional username
//

import SwiftUI

struct OnboardingView: View {
    @Environment(AccountRecoveryViewModel.self) private var recoveryVM
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    @State private var username: String = ""
    @State private var usernameErrorKey: String? = nil
    @State private var isCheckingUsername = false
    @State private var usernameIsAvailable: Bool? = nil
    @State private var showingRegistration = false
    @State private var showingRecovery = false
    @State private var showingNetworkSettings = false
    @State private var showingDeviceLink = false
    @State private var availabilityTask: Task<Void, Never>? = nil
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Top bar — network settings
                HStack {
                    Spacer()
                    Button {
                        #if os(macOS)
                        openSettings()
                        #else
                        showingNetworkSettings = true
                        #endif
                    } label: {
                        Text("[net]")
                            .font(CTFont.regular(12))
                            .foregroundColor(Color.CT.textDim)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("onboarding_network_settings"))
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                }

                Spacer()

                // Branding
                VStack(spacing: 60) {
                    CTLogoView(size: 100, color: Color.CT.text)

                    Text("constrcut_titlte")
                        .font(CTFont.bold(26))
                        .foregroundColor(Color.CT.text)
                        .tracking(8)

                    Text(LocalizedStringKey("onboarding_tagline"))
                        .font(CTFont.regular(12))
                        .foregroundColor(Color.CT.textDim)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 42)

                Spacer()

                // Username input + status
                VStack(alignment: .leading, spacing: 6) {
                    CTTextField(
                        placeholder: NSLocalizedString("onboarding_username_placeholder", comment: ""),
                        text: $username,
                        alignment: .center
                    )
                    .onChange(of: username) { _, newValue in
                        let lowered = newValue.lowercased()
                        if newValue != lowered {
                            username = lowered
                            return
                        }
                        validateUsername()
                        scheduleUsernameAvailabilityCheck()
                    }

                    if let errorKey = usernameErrorKey {
                        Text("> [!] \(NSLocalizedString(errorKey, comment: ""))")
                            .font(CTFont.regular(11))
                            .foregroundColor(Color.CT.danger)
                    } else if isCheckingUsername {
                        Text("> checking...")
                            .font(CTFont.regular(11))
                            .foregroundColor(Color.CT.textDim)
                    } else if let available = usernameIsAvailable {
                        Text(available ? "> [ok] available" : "> [!] taken")
                            .font(CTFont.regular(11))
                            .foregroundColor(available ? Color.CT.accentDim : Color.CT.danger)
                    }
                }
                .frame(maxWidth: 360)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)

                // Actions
                VStack(spacing: 8) {
                    CTButton(
                        label: NSLocalizedString("onboarding_create_identity", comment: "").uppercased(),
                        isEnabled: canProceed
                    ) {
                        showingRegistration = true
                    }
                    .frame(maxWidth: 360)
                    .padding(.bottom, 16)

                    HStack(spacing: 32) {
                        Button { showingRecovery = true } label: {
                            Text("[restore →]")
                                .font(CTFont.regular(13))
                                .foregroundColor(Color.CT.accentDim)
                        }
                        .buttonStyle(.plain)

                        Button { showingDeviceLink = true } label: {
                            Text("[link device →]")
                                .font(CTFont.regular(13))
                                .foregroundColor(Color.CT.textDim)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 52)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ctBackground()
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .navigationDestination(isPresented: $showingRegistration) {
                RegistrationFlowView(username: username.isEmpty ? nil : username)
            }
            .sheet(isPresented: $showingRecovery) {
                RecoveryEntryView()
                    .environment(recoveryVM)
            }
            .sheet(isPresented: $showingDeviceLink) {
                #if os(iOS)
                DeviceLinkScanView()
                #else
                DesktopLinkRequestView()
                #endif
            }
            .sheet(isPresented: $showingNetworkSettings) {
                NavigationStack {
                    NetworkSettingsView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(LocalizedStringKey("done")) {
                                    showingNetworkSettings = false
                                }
                            }
                        }
                }
            }
        }
    }

    private var canProceed: Bool {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return usernameErrorKey == nil
        }
        return usernameErrorKey == nil && usernameIsAvailable == true
    }

    private func validateUsername() {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            usernameErrorKey = nil
            usernameIsAvailable = nil
            return
        }

        if trimmed.count < 3 {
            usernameErrorKey = "username_too_short"
            usernameIsAvailable = nil
            return
        }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        if trimmed.rangeOfCharacter(from: allowed.inverted) != nil {
            usernameErrorKey = "username_invalid_chars"
            usernameIsAvailable = nil
        } else {
            usernameErrorKey = nil
        }
    }

    private func scheduleUsernameAvailabilityCheck() {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, usernameErrorKey == nil else {
            availabilityTask?.cancel()
            isCheckingUsername = false
            usernameIsAvailable = nil
            return
        }

        isCheckingUsername = true
        usernameIsAvailable = nil
        availabilityTask?.cancel()

        let requestedUsername = trimmed
        availabilityTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled {
                return
            }
            do {
                let result = try await UserServiceClient.shared.checkUsernameAvailability(username: requestedUsername)
                await MainActor.run {
                    if username.trimmingCharacters(in: .whitespacesAndNewlines) != requestedUsername {
                        return
                    }
                    isCheckingUsername = false
                    usernameIsAvailable = result.available
                    if !result.available, let reason = result.reason {
                        usernameErrorKey = reason
                    }
                }
            } catch {
                await MainActor.run {
                    if username.trimmingCharacters(in: .whitespacesAndNewlines) != requestedUsername {
                        return
                    }
                    isCheckingUsername = false
                    usernameIsAvailable = nil
                    usernameErrorKey = "username_check_failed"
                }
            }
        }
    }
}

#if DEBUG
#Preview {
    OnboardingView()
        .environment(AccountRecoveryViewModel())
}
#endif
