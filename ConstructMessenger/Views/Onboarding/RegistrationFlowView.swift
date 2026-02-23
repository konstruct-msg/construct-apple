//
//  RegistrationFlowView.swift
//  Construct Messenger
//
//  Registration flow with PoW
//

import SwiftUI

enum RegistrationStep: Equatable {
    case generatingKeys
    case fetchingChallenge
    case computingPoW
    case submittingRegistration
    case complete
    case error(String)
}

struct RegistrationFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var authViewModel: AuthViewModel
    
    let username: String?
    
    @State private var currentStep: RegistrationStep = .generatingKeys
    @State private var powProgress: Double = 0.0
    @State private var deviceId: String = ""
    @State private var challenge: String = ""
    @State private var difficulty: UInt32 = 6
    
    // Generated keys
    @State private var registrationBundle: String = ""
    @State private var signingKey: Data = Data()
    @State private var identityKey: Data = Data()
    
    var body: some View {
        VStack(spacing: 32) {
            // Progress indicator
            progressHeader
            
            Spacer()
            
            // Current step UI
            stepContent
            
            Spacer()
            
            // Action button
            if case .complete = currentStep {
                Button {
                    Log.info("👆 User pressed OK button", category: "Registration")
                    Log.info("   Sending 'DeviceRegistered' notification...", category: "Registration")
                    
                    // Notify ContentView to re-check device keys
                    NotificationCenter.default.post(name: NSNotification.Name("DeviceRegistered"), object: nil)
                    
                    Log.info("   Dismissing registration view...", category: "Registration")
                    dismiss()
                }
                label: {
                    Text("OK")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .cornerRadius(12)
                }
            } else if case .error(_) = currentStep {
                Button("Try Again") {
                    dismiss()
                }
                .buttonStyle(.bordered)
            } else {
                Button("Cancel") {
                    dismiss()
                }
                .foregroundColor(.red)
            }
        }
        .padding()
        .navigationBarBackButtonHidden(true)
        .task {
            await startRegistration()
        }
    }
    
    @ViewBuilder
    private var progressHeader: some View {
        VStack(spacing: 20) {
            switch currentStep {
            case .generatingKeys:
                stepIcon("key.fill", color: .blue)
                Text("Generating Keys")
                    .font(.title2)
                    .fontWeight(.semibold)
                ProgressView()
                    .scaleEffect(1.2)
                
            case .fetchingChallenge:
                stepIcon("network", color: .blue)
                Text("Connecting to Server")
                    .font(.title2)
                    .fontWeight(.semibold)
                ProgressView()
                    .scaleEffect(1.2)
                
            case .computingPoW:
                stepIcon("cpu.fill", color: .blue)
                Text("Proving You're Human")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                VStack(spacing: 12) {
                    // Clean single-color progress bar
                    ZStack(alignment: .leading) {
                        // Background track
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.gray.opacity(0.2))
                            .frame(height: 8)
                        
                        // Blue fill
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.blue)
                            .frame(width: max(8, UIScreen.main.bounds.width * 0.8 * CGFloat(powProgress)), height: 8)
                            .animation(.easeInOut(duration: 0.5), value: powProgress)
                    }
                    .frame(maxWidth: .infinity)
                    
                    HStack {
                        Text("\(Int(powProgress * 100))%")
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundColor(.blue)
                            .monospacedDigit() // Prevent width jumping
                        
                        Spacer()
                        
                        // Show difficulty level
                        HStack(spacing: 4) {
                            Image(systemName: "chart.bar.fill")
                                .font(.caption)
                            Text("Level \(difficulty)")
                                .font(.caption)
                        }
                        .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal)
                
            case .submittingRegistration:
                stepIcon("icloud.and.arrow.up", color: .blue)
                Text("Creating Account")
                    .font(.title2)
                    .fontWeight(.semibold)
                ProgressView()
                    .scaleEffect(1.2)
                
            case .complete:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.green)
                Text("Welcome!")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
            case .error(_):
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.red)
                Text("Something Went Wrong")
                    .font(.title2)
                    .fontWeight(.semibold)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
    
    @ViewBuilder
    private func stepIcon(_ systemName: String, color: Color) -> some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.2))
                .frame(width: 80, height: 80)
            Image(systemName: systemName)
                .font(.system(size: 40))
                .foregroundColor(color)
        }
    }
    
    @ViewBuilder
    private var stepContent: some View {
        VStack(spacing: 20) {
            switch currentStep {
            case .generatingKeys:
                InfoBubble(
                    icon: "shield.checkered",
                    text: "Creating unique cryptographic keys for your device"
                )
                
            case .fetchingChallenge:
                InfoBubble(
                    icon: "server.rack",
                    text: "Requesting anti-spam challenge from server"
                )
                
            case .computingPoW:
                VStack(spacing: 16) {
                    InfoBubble(
                        icon: "sparkles",
                        text: "This prevents bots and keeps the network spam-free. It may take a few minutes."
                    )
                }
                
            case .submittingRegistration:
                InfoBubble(
                    icon: "paperplane.fill",
                    text: "Registering your device with the server"
                )
                
            case .complete:
                VStack(spacing: 16) {
                    if let username = username, !username.isEmpty {
                        DetailRow(label: "Username", value: "@\(username)")
                    } else {
                        DetailRow(label: "Mode", value: "Anonymous")
                    }
                    
                    DetailRow(label: "Device ID", value: String(deviceId.prefix(16)) + "...")
                    
                    Text("Your device has been registered securely")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)
                
            case .error(let message):
                VStack(spacing: 16) {
                    Text(message)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                    
                    Text("Please check your internet connection and try again")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(.horizontal, 24)
    }
    
    // MARK: - Helper Views
    
    struct InfoBubble: View {
        let icon: String
        let text: String
        
        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(.blue)
                
                Text(text)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                
                Spacer()
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
        }
    }
    
    struct DetailRow: View {
        let label: String
        let value: String
        
        var body: some View {
            HStack {
                Text(label)
                    .foregroundColor(.secondary)
                Spacer()
                Text(value)
                    .fontWeight(.medium)
            }
            .font(.subheadline)
        }
    }
    
    private func infoCard(icon: String, title: String, description: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundColor(.blue)
                .frame(width: 48)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(12)
    }
    
    private func startRegistration() async {
        do {
            // Step 1: Generate keys
            currentStep = .generatingKeys
            
            // Generate real cryptographic keys using Rust core
            let (generatedDeviceId, bundleJson, signingKeyData, identityKeyData) = try CryptoManager.shared.generateRegistrationBundle()
            
            // Store for later use
            deviceId = generatedDeviceId
            registrationBundle = bundleJson
            signingKey = signingKeyData
            identityKey = identityKeyData
            
            Log.info("✅ Generated keys: device_id=\(generatedDeviceId)", category: "Registration")
            
            // Debug: compare verifying key in bundle vs derived from signing secret
            if let bundleData = bundleJson.data(using: .utf8),
               let bundleDict = try? JSONSerialization.jsonObject(with: bundleData) as? [String: Any],
               let bundleVerifyingKey = bundleDict["verifying_key"] as? String {
                Log.info("🔐 Registration bundle verifying_key: \(bundleVerifyingKey)", category: "Registration")
            } else {
                Log.info("⚠️ Could not parse verifying_key from registration bundle", category: "Registration")
            }

            do {
                let derivedVerifyingKey = try deriveVerifyingKeyFromSecret(identitySecretKey: [UInt8](signingKeyData))
                let derivedBase64 = Data(derivedVerifyingKey).base64EncodedString()
                Log.info("🔐 Derived verifying key from signing_secret: \(derivedBase64)", category: "Registration")
            } catch {
                Log.info("⚠️ Failed to derive verifying key from signing_secret: \(error.localizedDescription)", category: "Registration")
            }
            try await Task.sleep(for: .seconds(0.3)) // Brief pause for UI feedback
            
            // Step 2: Fetch challenge
            currentStep = .fetchingChallenge
            let challengeResponse = try await AuthServiceClient.shared.getPowChallenge()
            challenge = challengeResponse.challenge
            difficulty = challengeResponse.difficulty
            
            Log.info("✅ Challenge fetched: difficulty=\(difficulty)", category: "Registration")
            
            // Step 3: Compute PoW with real-time progress
            currentStep = .computingPoW
            
            Log.info("🔨 Starting PoW computation (difficulty: \(difficulty))...", category: "Registration")
            
            // ✅ Use real progress from Rust with smooth animation
            let solution = await ProofOfWorkManager.computeWithProgress(
                challenge: challenge,
                difficulty: difficulty,
                onProgress: { progress in
                    // Already on main thread from observer
                    // Use withAnimation for smooth progress bar
                    withAnimation(.easeInOut(duration: 0.5)) {
                        self.powProgress = Double(progress)
                    }
                }
            )
            
            Log.info("✅ PoW complete! nonce=\(solution.nonce)", category: "Registration")
            
            // Step 4: Submit registration
            currentStep = .submittingRegistration
            let registerData = try await AuthServiceClient.shared.registerDevice(
                username: username,
                deviceId: deviceId,
                registrationBundle: registrationBundle,
                challenge: challenge,
                powSolution: solution
            )
            Log.info("✅ Registration successful! userId=\(registerData.userId)", category: "Registration")
            
            // Step 5: Complete
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            currentStep = .complete
            
            // ========================================
            // SAVE AND VERIFY ALL REGISTRATION DATA
            // ========================================
            
            Log.info("💾 Starting data persistence...", category: "Registration")
            
            // 1. Save device credentials to Keychain
            Log.info("1️⃣ Saving device credentials to Keychain...", category: "Registration")
            KeychainManager.shared.saveDeviceID(deviceId)
            KeychainManager.shared.saveDeviceSigningKey(signingKey)
            KeychainManager.shared.saveDeviceIdentityKey(identityKey)
            
            // 2. Verify Keychain saves
            Log.info("2️⃣ Verifying Keychain data...", category: "Registration")
            let savedDeviceId = KeychainManager.shared.loadDeviceID()
            let savedSigningKey = KeychainManager.shared.loadDeviceSigningKey()
            let savedIdentityKey = KeychainManager.shared.loadDeviceIdentityKey()
            
            let keychainOK = savedDeviceId != nil && savedSigningKey != nil && savedIdentityKey != nil
            
            if keychainOK {
                Log.info("   ✅ deviceId: \(savedDeviceId!.prefix(16))... (\(savedDeviceId!.count) chars)", category: "Registration")
                Log.info("   ✅ signingKey: \(savedSigningKey!.count) bytes", category: "Registration")
                Log.info("   ✅ identityKey: \(savedIdentityKey!.count) bytes", category: "Registration")
                Log.info("   ✅ isDeviceRegistered: \(KeychainManager.shared.isDeviceRegistered())", category: "Registration")
            } else {
                Log.error("   ❌ Keychain verification FAILED!", category: "Registration")
                Log.error("      deviceId: \(savedDeviceId != nil ? "✓" : "✗")", category: "Registration")
                Log.error("      signingKey: \(savedSigningKey != nil ? "✓" : "✗")", category: "Registration")
                Log.error("      identityKey: \(savedIdentityKey != nil ? "✓" : "✗")", category: "Registration")
            }
            
            // 3. Save session tokens + userId
            Log.info("3️⃣ Saving session tokens + userId...", category: "Registration")
            SessionManager.shared.saveTokens(
                accessToken: registerData.sessionToken,
                refreshToken: registerData.refreshToken,
                expiresIn: Int(registerData.expires - Int64(Date().timeIntervalSince1970)),
                userId: registerData.userId
            )
            
            // 4. Verify session tokens
            Log.info("4️⃣ Verifying session tokens...", category: "Registration")
            // Tokens are in published properties after saveTokens()
            let savedAccessToken = SessionManager.shared.sessionToken
            let savedRefreshToken = SessionManager.shared.refreshToken
            
            if savedAccessToken != nil && savedRefreshToken != nil {
                Log.info("   ✅ accessToken: \(savedAccessToken!.prefix(20))...", category: "Registration")
                Log.info("   ✅ refreshToken: \(savedRefreshToken!.prefix(20))...", category: "Registration")
                Log.info("   ✅ isSessionValid: \(SessionManager.shared.isSessionValid)", category: "Registration")
            } else {
                Log.error("   ❌ Session tokens verification FAILED!", category: "Registration")
            }
            
            // 5. Update AuthViewModel
            Log.info("5️⃣ Updating AuthViewModel...", category: "Registration")
            await MainActor.run {
                authViewModel.finalizeDeviceRegistration(userId: registerData.userId, username: username)
            }
            
            Log.info("   ✅ isAuthenticated: \(authViewModel.isAuthenticated)", category: "Registration")
            Log.info("   ✅ currentUserId: \(authViewModel.currentUserId ?? "nil")", category: "Registration")
            
            // 6. Final verification summary
            Log.info("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", category: "Registration")
            Log.info("📊 REGISTRATION DATA SUMMARY:", category: "Registration")
            Log.info("   Device ID:    \(savedDeviceId?.prefix(16) ?? "MISSING")...", category: "Registration")
            Log.info("   User ID:      \(registerData.userId.prefix(8))...", category: "Registration")
            Log.info("   Username:     \(username ?? "anonymous")", category: "Registration")
            Log.info("   Keychain:     \(keychainOK ? "✅" : "❌")", category: "Registration")
            Log.info("   Session:      \(savedAccessToken != nil ? "✅" : "❌")", category: "Registration")
            Log.info("   AuthViewModel: \(authViewModel.isAuthenticated ? "✅" : "❌")", category: "Registration")
            Log.info("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", category: "Registration")
            
            if keychainOK && savedAccessToken != nil && authViewModel.isAuthenticated {
                Log.info("🎉 ALL CHECKS PASSED - Ready for main app!", category: "Registration")
            } else {
                Log.error("⚠️ SOME CHECKS FAILED - App may not work correctly", category: "Registration")
            }
            
        } catch {
            currentStep = .error(error.localizedDescription)
        }
    }
}

#Preview {
    NavigationStack {
        RegistrationFlowView(username: "john_smith")
    }
}
