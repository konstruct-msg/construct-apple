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

// MARK: - Converging Signal Animation

/// Dots oscillate vertically. As `progress` increases from 0→1, dots
/// settle left-to-right onto the center line — like a signal locking in.
struct ConvergingSignalView: View {
    let progress: Double   // 0.0 → 1.0

    private let dotCount = 22
    @State private var phases: [Double] = []
    @State private var tick: Double = 0
    private let animTimer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        Canvas { context, size in
            guard phases.count == dotCount else { return }
            let w = size.width
            let h = size.height
            let cy = h / 2.0
            let spacing = w / CGFloat(dotCount - 1)
            let maxAmp = h * 0.42

            // Connecting line
            var line = Path()
            for i in 0..<dotCount {
                let x = CGFloat(i) * spacing
                let y = yForDot(i: i, cy: cy, maxAmp: maxAmp)
                if i == 0 { line.move(to: .init(x: x, y: y)) }
                else      { line.addLine(to: .init(x: x, y: y)) }
            }
            context.stroke(line, with: .color(.blue.opacity(0.18)), lineWidth: 1.0)

            // Dots
            for i in 0..<dotCount {
                let norm = Double(i) / Double(dotCount - 1)
                let x    = CGFloat(i) * spacing
                let y    = yForDot(i: i, cy: cy, maxAmp: maxAmp)
                let settled = norm < progress
                let r: CGFloat = settled ? 2.5 : 2.0
                let alpha = settled
                    ? 0.9
                    : 0.3 + 0.35 * abs(sin(phases[i] + tick))
                context.fill(
                    Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                    with: .color(.blue.opacity(alpha))
                )
            }
        }
        .onAppear {
            if phases.isEmpty {
                phases = (0..<dotCount).map { _ in Double.random(in: 0 ..< 2 * .pi) }
            }
        }
        .onReceive(animTimer) { _ in tick += 0.05 }
    }

    private func yForDot(i: Int, cy: CGFloat, maxAmp: CGFloat) -> CGFloat {
        guard !phases.isEmpty else { return cy }
        let norm = Double(i) / Double(dotCount - 1)
        guard norm >= progress else { return cy } // settled
        let relDist = progress < 1.0 ? (norm - progress) / (1.0 - progress) : 0.0
        return cy + maxAmp * CGFloat(relDist) * CGFloat(sin(phases[i] + tick))
    }
}

// MARK: - Pure UI Stage View (no logic, safe for Previews)

struct RegistrationStageView: View {
    let step: RegistrationStep
    var powProgress: Double = 0.0
    var difficulty: UInt32 = 8
    var deviceId: String = ""
    var username: String? = nil
    var onComplete: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            switch step {
            case .generatingKeys, .fetchingChallenge, .computingPoW, .submittingRegistration:
                preparingContent
            case .complete:
                completeContent
            case .error(let msg):
                errorContent(msg)
            }
            Spacer()
            actionButton.padding(.bottom, 20)
        }
        .padding(.horizontal, 32)
    }

    // MARK: Preparing (all pre-complete steps unified)

    private var preparingContent: some View {
        VStack(spacing: 44) {
            VStack(spacing: 8) {
                Text("Establishing trust")
                    .font(.title2).fontWeight(.semibold)
                Text("Your device is joining the network")
                    .font(.subheadline).foregroundColor(.secondary)
            }

            ConvergingSignalView(progress: unifiedProgress)
                .frame(height: 72)

            Text(phaseLabel)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .id(phaseLabel)
                .transition(.opacity.animation(.easeInOut(duration: 0.4)))
        }
    }

    // MARK: Complete

    private var completeContent: some View {
        VStack(spacing: 32) {
            

            Text("Welcome")
                .font(.largeTitle).fontWeight(.bold)

            VStack(spacing: 16) {
                if let u = username, !u.isEmpty {
                    DetailRow(label: "Username", value: "@\(u)")
                } else {
                    DetailRow(label: "Mode", value: "Anonymous")
                }
                if !deviceId.isEmpty {
                    DetailRow(label: "Device ID", value: String(deviceId.prefix(16)) + "…")
                }
                
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
        }
    }

    // MARK: Error

    private func errorContent(_ message: String) -> some View {
        VStack(spacing: 24) {
 
            Text("Something went wrong")
                .font(.title2).fontWeight(.semibold)
            Text(message)
                .font(.body).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: Action button

    @ViewBuilder
    private var actionButton: some View {
        switch step {
        case .complete:
            Button { onComplete?() } label: {
                Text("Continue")
                    .font(.headline).foregroundColor(.white)
                    .frame(maxWidth: .infinity).padding()
                    .background(Color("ButtonColor")).cornerRadius(18)
            }
        case .error:
            Button("Try Again") { onDismiss?() }.buttonStyle(.bordered)
        default:
            Button("Cancel") { onDismiss?() }.foregroundColor(.secondary)
        }
    }

    // MARK: Helpers

    /// Maps all pre-complete steps to a single 0→1 value for the animation
    private var unifiedProgress: Double {
        switch step {
        case .generatingKeys:         return 0.04
        case .fetchingChallenge:      return 0.12
        case .computingPoW:           return 0.18 + powProgress * 0.76
        case .submittingRegistration: return 0.97
        default:                      return 1.0
        }
    }

    private var phaseLabel: String {
        switch step {
        case .generatingKeys, .fetchingChallenge:
            return "entropy collected"
        case .computingPoW:
            return powProgress >= 0.98 ? "solution found" : "nonce search"
        case .submittingRegistration:
            return "solution found"
        default:
            return ""
        }
    }

    // MARK: Sub-views

    struct DetailRow: View {
        let label: String; let value: String
        var body: some View {
            HStack {
                Text(label).foregroundColor(.secondary)
                Spacer()
                Text(value).fontWeight(.medium)
            }.font(.subheadline)
        }
    }
}

// MARK: - Container (manages logic)

struct RegistrationFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var authViewModel: AuthViewModel

    let username: String?

    @State private var currentStep: RegistrationStep = .generatingKeys
    @State private var hasStarted = false
    @State private var powProgress: Double = 0.0
    @State private var deviceId: String = ""
    @State private var challenge: String = ""
    @State private var difficulty: UInt32 = 6

    // Generated keys
    @State private var registrationBundle: String = ""
    @State private var signingKey: Data = Data()
    @State private var identityKey: Data = Data()

    var body: some View {
        RegistrationStageView(
            step: currentStep,
            powProgress: powProgress,
            difficulty: difficulty,
            deviceId: deviceId,
            username: username,
            onComplete: {
                Log.info("👆 User pressed Continue", category: "Registration")
                NotificationCenter.default.post(name: NSNotification.Name("DeviceRegistered"), object: nil)
                dismiss()
            },
            onDismiss: { dismiss() }
        )
        .navigationBarBackButtonHidden(true)
        .task {
            guard !hasStarted else { return }
            hasStarted = true
            await startRegistration()
        }
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
            Log.error("❌ Registration failed: \(error)", category: "Registration")
            currentStep = .error(error.localizedDescription)
        }
    }
}

// MARK: - Previews (frozen stages — no logic runs)

#Preview("Entropy collected") {
    NavigationStack {
        RegistrationStageView(step: .generatingKeys).padding()
    }
}

#Preview("Nonce search — 0%") {
    NavigationStack {
        RegistrationStageView(step: .computingPoW, powProgress: 0.0, difficulty: 8).padding()
    }
}

#Preview("Nonce search — 55%") {
    NavigationStack {
        RegistrationStageView(step: .computingPoW, powProgress: 0.55, difficulty: 8).padding()
    }
}

#Preview("Solution found") {
    NavigationStack {
        RegistrationStageView(step: .computingPoW, powProgress: 1.0, difficulty: 8).padding()
    }
}

#Preview("Submitting") {
    NavigationStack {
        RegistrationStageView(step: .submittingRegistration).padding()
    }
}

#Preview("Complete — with username") {
    NavigationStack {
        RegistrationStageView(
            step: .complete,
            deviceId: "f3b8d583698feab0eb8ee8008a1944c6",
            username: "john_smith"
        ).padding()
    }
}

#Preview("Complete — anonymous") {
    NavigationStack {
        RegistrationStageView(
            step: .complete,
            deviceId: "f3b8d583698feab0eb8ee8008a1944c6"
        ).padding()
    }
}

#Preview("Error") {
    NavigationStack {
        RegistrationStageView(
            step: .error("Could not connect to server. The operation couldn't be completed.")
        ).padding()
    }
}
