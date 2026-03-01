//
//  OnboardingView.swift
//  Construct Messenger
//
//  Passwordless onboarding with optional username
//

import SwiftUI

struct OnboardingView: View {
    @State private var username: String = ""
    @State private var usernameErrorKey: String? = nil
    @State private var isCheckingUsername = false
    @State private var usernameIsAvailable: Bool? = nil
    @State private var showingRegistration = false
    @State private var showingRecovery = false
    @State private var showingNetworkSettings = false
    @State private var availabilityTask: Task<Void, Never>? = nil
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()
                
                // Logo/Branding
                VStack(spacing: 12) {
                    Image("KonstructLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 130, height: 130)
                        .padding(.bottom, 40)
                                        
                    Text("KONSTRUCT")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .tracking(9)
                    
                    Text("onboarding_tagline")
                        .font(.subheadline)
                        .padding(.vertical, 8)
                    
                }
                .padding(.bottom, 80)
                
                // Username input (optional)
                VStack(alignment: .leading, spacing: 8) {
                    
                    TextField("onboarding_username_placeholder", text: $username)
                        .multilineTextAlignment(.center)
                        .font(.body.monospaced())
                        .frame(height: 30)
                        .padding(12)
                        .background(Color(.systemGray6))
                        .cornerRadius(18)
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
                .frame(maxWidth: 420)
                .padding(.horizontal, 32)
                
                Spacer()
                
                // Primary actions
                VStack(spacing: 16) {
                    Button {
                        showingRegistration = true
                    } label: {
                        Text("onboarding_create_identity")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(canProceed ? Color.AppBrand.button : Color.gray)
                            .cornerRadius(18)
                    }
                    .padding(.vertical, 8)
                    .disabled(!canProceed)
                                        
                    Button {
                        showingRecovery = true
                    } label: {
                        Text("onboarding_restore")
                            .font(.subheadline)
                            .foregroundColor(Color.AppBrand.second)
                    }
                    .padding(.vertical, 8)
                }
                .frame(maxWidth: 420)
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                // Lattice background — visual nod to lattice-based cryptography
                LatticeBackgroundView()
                    .ignoresSafeArea()
                    .opacity(0.8)
            }
            .navigationDestination(isPresented: $showingRegistration) {
                RegistrationFlowView(username: username.isEmpty ? nil : username)
            }
            .sheet(isPresented: $showingRecovery) {
                // TODO: Recovery flow (Week 5)
                Text("onboarding_recovery_coming_soon")
            }
            .sheet(isPresented: $showingNetworkSettings) {
                NavigationStack {
                    NetworkSettingsView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingNetworkSettings = true
                    } label: {
                        Image(systemName: "network")
                    }
                    .foregroundStyle(Color.AppBrand.second)
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

#Preview {
    OnboardingView()
}
