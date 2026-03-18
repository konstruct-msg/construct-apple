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
            VStack(spacing: 32) {
                // Logo/Branding
                VStack(spacing: 12) {
                    Image("KonstructLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 120, height: 120)

                    Image("MainTitle")
                        .padding(.top, 12)

                    Text("onboarding_tagline")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                }
                .padding(.top, 32)

                Spacer()
                
                // Username input (optional)
                VStack(alignment: .center, spacing: 8) {

                    TextField("onboarding_username_placeholder", text: $username)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 14, weight: .regular, design: .monospaced))
                        .frame(height: 30)
                        .padding(12)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(8)
                        #if os(macOS)
                        .textFieldStyle(.plain)
                        #endif
                        .onChange(of: username) { oldValue, newValue in
                            let lowered = newValue.lowercased()
                            if newValue != lowered {
                                username = lowered
                                return
                            }
                            validateUsername()
                            scheduleUsernameAvailabilityCheck()
                        }

                    if let usernameErrorKey {
                        Text(LocalizedStringKey(usernameErrorKey))
                            .font(.caption)
                            .foregroundColor(.red)
                    } else if isCheckingUsername {
                        Text("username_checking")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if let available = usernameIsAvailable {
                        Text(LocalizedStringKey(available ? "username_available" : "username_unavailable"))
                            .font(.caption)
                            .foregroundColor(available ? Color.AppStatus.success : .red)
                    }
                    
                }
                .frame(maxWidth: 360)
                .padding(.horizontal, 24)

                // Primary actions
                VStack(spacing: 12) {
                    Button {
                        showingRegistration = true
                    } label: {
                        Text("onboarding_create_identity")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(canProceed ? Color.AppBrand.button : Color.gray.opacity(0.5))
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canProceed)

                    Button {
                        showingRecovery = true
                    } label: {
                        Text("onboarding_restore")
                            .font(.subheadline)
                            .foregroundColor(Color.blue)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)

                    Button {
                        showingDeviceLink = true
                    } label: {
                        Text("onboarding_link_device")
                            .font(.subheadline)
                            .foregroundColor(Color.secondary)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: 360)
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
//            .background {
//                // Lattice background — visual nod to lattice-based cryptography
//                LatticeBackgroundView()
//                    .ignoresSafeArea()
//                    .opacity(0.8)
//            }
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
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        #if os(macOS)
                        openSettings()
                        #else
                        showingNetworkSettings = true
                        #endif
                    } label: {
                        Image(systemName: "network")
                    }
                    .foregroundStyle(Color.blue)
                    .accessibilityLabel(Text("onboarding_network_settings"))
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
