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

// MARK: - Pure UI Stage View (no logic, safe for Previews)

struct RegistrationStageView: View {
    let step: RegistrationStep
    var powProgress: Double = 0.0
    var difficulty: UInt32 = 8
    var deviceId: String = ""
    var username: String? = nil
    var onComplete: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    @State private var signalCollapsed = false
    @State private var showComplete = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            switch step {
            case .generatingKeys, .fetchingChallenge, .computingPoW, .submittingRegistration:
                preparingContent
                    .transition(.opacity)
            case .complete:
                if showComplete {
                    completeContent
                        .transition(.opacity.animation(.easeIn(duration: 0.4)))
                } else {
                    preparingContent
                }
            case .error(let msg):
                errorContent(msg)
            }
            Spacer()
            actionButton.padding(.bottom, 20)
        }
        .padding(.horizontal, 32)
        .onChange(of: step) { _, newStep in
            if newStep == .complete {
                signalCollapsed = true
                // Wait for collapse animation, then show complete screen
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
                    withAnimation { showComplete = true }
                }
            }
        }
    }

    // MARK: Preparing (all pre-complete steps unified)

    private var preparingContent: some View {
        VStack(spacing: 44) {
            VStack(spacing: 8) {
                Text(LocalizedStringKey("reg_establishing_trust"))
                    .font(CTFont.bold(18))
                    .foregroundColor(Color.CT.text)
                Text(LocalizedStringKey("reg_joining_network"))
                    .font(CTFont.regular(13))
                    .foregroundColor(Color.CT.textDim)
            }

            ConvergingSignalView(progress: unifiedProgress, collapsed: signalCollapsed)
                .frame(height: 72)

            Text(phaseLabel)
                .font(CTFont.regular(11))
                .foregroundColor(Color.CT.textDim)
                .id(phaseLabel)
                .transition(.opacity.animation(.easeInOut(duration: 0.4)))
        }
    }

    // MARK: Complete

    private var completeContent: some View {
        VStack(spacing: 28) {
            Text(LocalizedStringKey("reg_welcome"))
                .font(CTFont.bold(24))
                .foregroundColor(Color.CT.text)

            VStack(spacing: 0) {
                if let u = username, !u.isEmpty {
                    DetailRow(label: NSLocalizedString("reg_label_username", comment: ""), value: "@\(u)")
                    CTSep()
                } else {
                    DetailRow(label: NSLocalizedString("reg_label_mode", comment: ""), value: NSLocalizedString("reg_mode_anonymous", comment: ""))
                    CTSep()
                }
                if !deviceId.isEmpty {
                    DetailRow(label: NSLocalizedString("reg_label_device_id", comment: ""), value: String(deviceId.prefix(16)) + "…")
                }
            }
            .background(Color.CT.bgMsg)
            .overlay(Rectangle().stroke(Color.CT.noise, lineWidth: 0.5))
        }
    }

    // MARK: Error

    private func errorContent(_ message: String) -> some View {
        VStack(spacing: 20) {
            Text(LocalizedStringKey("reg_error_title"))
                .font(CTFont.bold(18))
                .foregroundColor(Color.CT.danger)
            Text(message)
                .font(CTFont.regular(13))
                .foregroundColor(Color.CT.textDim)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: Action button

    @ViewBuilder
    private var actionButton: some View {
        switch step {
        case .complete:
            CTButton(label: NSLocalizedString("reg_continue", comment: "").uppercased()) {
                onComplete?()
            }
        case .error:
            CTButton(label: NSLocalizedString("reg_try_again", comment: "").uppercased(), isDestructive: true) {
                onDismiss?()
            }
        default:
            Button(NSLocalizedString("reg_cancel", comment: "")) { onDismiss?() }
                .font(CTFont.regular(13))
                .foregroundColor(Color.CT.textDim)
                .buttonStyle(.plain)
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
            return NSLocalizedString("reg_phase_entropy", comment: "")
        case .computingPoW:
            return NSLocalizedString(powProgress >= 0.98 ? "reg_phase_solution" : "reg_phase_nonce", comment: "")
        case .submittingRegistration:
            return NSLocalizedString("reg_phase_solution", comment: "")
        default:
            return ""
        }
    }

    // MARK: Sub-views

    struct DetailRow: View {
        let label: String; let value: String
        var body: some View {
            HStack {
                Text(label)
                    .font(CTFont.regular(12))
                    .foregroundColor(Color.CT.textDim)
                Spacer()
                Text(value)
                    .font(CTFont.bold(12))
                    .foregroundColor(Color.CT.text)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
    }
}

// MARK: - Container (manages logic)

struct RegistrationFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthViewModel.self) private var authViewModel

    let username: String?

    @State private var currentStep: RegistrationStep = .generatingKeys
    @State private var hasStarted = false
    @State private var powProgress: Double = 0.0
    @State private var deviceId: String = ""
    @State private var challenge: String = ""
    @State private var difficulty: UInt32 = 6

    // Generated keys
    @State private var registrationBundle: RegistrationBundleFields? = nil
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
                Log.info("User pressed Continue", category: "Registration")
                authViewModel.hasRegisteredDeviceKeys = true
                dismiss()
            },
            onDismiss: { dismiss() }
        )
        .ctBackground()
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        #endif
        .onAppear { authViewModel.isRegistrationInProgress = true }
        .onDisappear { authViewModel.isRegistrationInProgress = false }
        .task {
            guard !hasStarted else { return }
            // Guard against re-running if keys were already saved (e.g. view recreated during dismiss)
            guard !KeychainManager.shared.isDeviceRegistered() else { return }
            hasStarted = true
            await startRegistration()
        }
    }

    private func startRegistration() async {
        do {
            // Step 1: Generate keys (or reuse from a previous failed attempt)
            currentStep = .generatingKeys

            let savedId = KeychainManager.shared.loadDeviceID()
            let savedSigning = KeychainManager.shared.loadDeviceSigningKey()
            let savedIdentity = KeychainManager.shared.loadDeviceIdentityKey()
            let savedBundle = RegistrationFlowView.loadSavedBundle()

            if let sid = savedId, let ssign = savedSigning, let sidentity = savedIdentity,
               let sbundle = savedBundle {
                // Reuse keys from a previous attempt that failed mid-flight.
                // Don't regenerate — the keys may already be registered on the server
                // (the RPC could have timed out after the server persisted the data).
                Log.info("Reusing previously generated keys: device_id=\(sid)", category: "Registration")
                deviceId = sid
                signingKey = ssign
                identityKey = sidentity
                registrationBundle = sbundle
            } else {
                // Generate real cryptographic keys using Rust core
                let (generatedDeviceId, bundle, signingKeyData, identityKeyData) = try CryptoManager.shared.generateRegistrationBundle()

                deviceId = generatedDeviceId
                registrationBundle = bundle
                signingKey = signingKeyData
                identityKey = identityKeyData

                Log.info("Generated keys: device_id=\(generatedDeviceId)", category: "Registration")
                let verifyingKeyB64 = Data(bundle.verifyingKey).base64EncodedString()
                Log.info("Registration bundle verifying_key: \(verifyingKeyB64)", category: "Registration")

                do {
                    let derivedVerifyingKey = try deriveVerifyingKeyFromSecret(identitySecretKey: [UInt8](signingKeyData))
                    let derivedBase64 = Data(derivedVerifyingKey).base64EncodedString()
                    Log.info("Derived verifying key from signing_secret: \(derivedBase64)", category: "Registration")
                } catch {
                    Log.info("Failed to derive verifying key from signing_secret: \(error.localizedDescription)", category: "Registration")
                }

                // Save device keys and bundle IMMEDIATELY — before any network call.
                // If the registration RPC succeeds on the server but the response is
                // lost (deadline exceeded), the next launch will find these keys and
                // successfully authenticate instead of generating a new identity.
                KeychainManager.shared.saveDeviceID(deviceId)
                KeychainManager.shared.saveDeviceSigningKey(signingKey)
                KeychainManager.shared.saveDeviceIdentityKey(identityKey)
                RegistrationFlowView.saveBundle(bundle)
                Log.info("Device keys saved to Keychain before RPC", category: "Registration")
            }
            try await Task.sleep(for: .seconds(0.3)) // Brief pause for UI feedback
            
            // Step 2: Fetch challenge
            currentStep = .fetchingChallenge
            let challengeResponse = try await AuthServiceClient.shared.getPowChallenge()
            challenge = challengeResponse.challenge
            difficulty = challengeResponse.difficulty
            
            Log.info("Challenge fetched: difficulty=\(difficulty)", category: "Registration")
            
            // Step 3: Compute PoW with real-time progress
            currentStep = .computingPoW
            
            Log.info("Starting PoW computation (difficulty: \(difficulty))...", category: "Registration")
            
            // Use real progress from Rust with smooth animation
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
            
            Log.info("PoW complete! nonce=\(solution.nonce)", category: "Registration")

            // Step 4: Submit registration
            currentStep = .submittingRegistration
            let registerData = try await AuthServiceClient.shared.registerDevice(
                username: username,
                deviceId: deviceId,
                registrationBundle: registrationBundle ?? RegistrationBundleFields(
                    identityPublic: [], signedPrekeyPublic: [], signature: [], verifyingKey: [], suiteId: 0
                ),
                challenge: challenge,
                powSolution: solution
            )
            Log.info("Registration successful! userId=\(registerData.userId)", category: "Registration")

            // Clear the pending bundle — it is no longer needed after successful registration.
            RegistrationFlowView.clearSavedBundle()
            
            // Step 5: Complete
            #if canImport(UIKit)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            #endif
            currentStep = .complete
            
            // ========================================
            // SAVE AND VERIFY ALL REGISTRATION DATA
            // ========================================
            
            Log.info("Starting data persistence...", category: "Registration")
            
            // 1. Device credentials are already in Keychain (saved before RPC).
            //    Re-save to be sure (idempotent; protects against the reuse path above
            //    where keys were loaded from Keychain but not yet saved for this run).
            Log.info("Confirming device credentials in Keychain...", category: "Registration")
            KeychainManager.shared.saveDeviceID(deviceId)
            KeychainManager.shared.saveDeviceSigningKey(signingKey)
            KeychainManager.shared.saveDeviceIdentityKey(identityKey)
            
            // 2. Verify Keychain saves
            Log.info("Verifying Keychain data...", category: "Registration")
            let savedDeviceId = KeychainManager.shared.loadDeviceID()
            let savedSigningKey = KeychainManager.shared.loadDeviceSigningKey()
            let savedIdentityKey = KeychainManager.shared.loadDeviceIdentityKey()
            
            let keychainOK = savedDeviceId != nil && savedSigningKey != nil && savedIdentityKey != nil
            
            if keychainOK {
                Log.info("   deviceId: \(savedDeviceId!.prefix(16))... (\(savedDeviceId!.count) chars)", category: "Registration")
                Log.info("   signingKey: \(savedSigningKey!.count) bytes", category: "Registration")
                Log.info("   identityKey: \(savedIdentityKey!.count) bytes", category: "Registration")
                Log.info("   isDeviceRegistered: \(KeychainManager.shared.isDeviceRegistered())", category: "Registration")
            } else {
                Log.error("   Keychain verification FAILED!", category: "Registration")
                Log.error("      deviceId: \(savedDeviceId != nil ? "✓" : "✗")", category: "Registration")
                Log.error("      signingKey: \(savedSigningKey != nil ? "✓" : "✗")", category: "Registration")
                Log.error("      identityKey: \(savedIdentityKey != nil ? "✓" : "✗")", category: "Registration")
            }
            
            // 3. Save session tokens + userId
            Log.info("Saving session tokens + userId...", category: "Registration")
            AuthSessionManager.shared.saveTokens(
                accessToken: registerData.sessionToken,
                refreshToken: registerData.refreshToken,
                expiresIn: Int(registerData.expires - Int64(Date().timeIntervalSince1970)),
                userId: registerData.userId
            )
            VeilProxyManager.shared.configureFromServer(cert: registerData.veilBridgeCert ?? "")
            
            // 4. Verify session tokens
            Log.info("Verifying session tokens...", category: "Registration")
            // Tokens are in published properties after saveTokens()
            let savedAccessToken = AuthSessionManager.shared.sessionToken
            let savedRefreshToken = AuthSessionManager.shared.refreshToken
            
            if savedAccessToken != nil && savedRefreshToken != nil {
                Log.info("   accessToken: \(savedAccessToken!.prefix(20))...", category: "Registration")
                Log.info("   refreshToken: \(savedRefreshToken!.prefix(20))...", category: "Registration")
                Log.info("   isSessionValid: \(AuthSessionManager.shared.isSessionValid)", category: "Registration")
            } else {
                Log.error("   Session tokens verification FAILED!", category: "Registration")
            }
            
            // 5. Update AuthViewModel
            Log.info("Updating AuthViewModel...", category: "Registration")
            await MainActor.run {
                authViewModel.finalizeDeviceRegistration(userId: registerData.userId, username: username)
            }
            // Record the SPK upload timestamp so PreKeyRotationService can track SPK age.
            PreKeyRotationService.shared.recordSpkUpload()
            
            // 6. Upload initial one-time prekeys (100 OTPKs for full Signal Protocol)
            Log.info("Uploading initial one-time prekeys...", category: "Registration")
            do {
                let uploadedCount = try await OtpkReplenishmentService.generateAndUpload(
                    count: 100,
                    deviceId: deviceId,
                    replaceExisting: true
                )
                Log.info("   Uploaded \(uploadedCount) one-time prekeys", category: "Registration")
            } catch {
                Log.error("   OTPK upload failed (non-fatal): \(error)", category: "Registration")
            }

            // 6.1 Bootstrap initial Stealth / Privacy Pass tokens (first batch).
            // Runs detached after registration (right after PoW + keys).
            // Uses special bootstrap path that bypasses cooldown.
            Log.info("Bootstrapping initial stealth tokens (Privacy Pass)...", category: "Registration")
            Task.detached(priority: .utility) {
                await BlindTokenService.shared.bootstrapInitialBatch()
            }

            // 6.5 Upload Kyber SPK + OTPKs in a single request (detached — survives view dismissal)
            Log.info("Uploading Kyber SPK + OTPKs (PQC)...", category: "Registration")
            do {
                let spkId = PQCKeyManager.shared.kyberSPKId()
                let (spkPublicKey, _) = try PQCKeyManager.shared.generateAndStoreKyberSPK(keyId: spkId)
                let spkSig = try PQCKeyManager.signKyberKey(publicKey: spkPublicKey)
                let spkTuple = (keyId: spkId, publicKey: spkPublicKey, signature: spkSig)
                let capturedDeviceId = deviceId
                Task.detached(priority: .utility) {
                    do {
                        let kyberCount = try await PQCKeyManager.generateAndUploadKyberOtpks(
                            count: 50,
                            deviceId: capturedDeviceId,
                            kyberSignedPreKey: spkTuple
                        )
                        UserDefaults.standard.set(true, forKey: "pqcKyberSPKMigrationV1Done")
                        Log.info("   Kyber SPK uploaded (keyId=\(spkId))", category: "Registration")
                        Log.info("   Kyber OTPKs on server: \(kyberCount)", category: "Registration")
                    } catch {
                        Log.error("   Kyber PQC upload failed (will retry on next launch): \(error)", category: "Registration")
                    }
                }
            } catch {
                Log.error("   Kyber PQC key generation failed: \(error)", category: "Registration")
            }
            
            Log.info("   isAuthenticated: \(authViewModel.isAuthenticated)", category: "Registration")
            Log.info("   currentUserId: \(authViewModel.currentUserId ?? "nil")", category: "Registration")
            
            // 7. Final verification summary
            Log.info("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", category: "Registration")
            Log.info("REGISTRATION DATA SUMMARY:", category: "Registration")
            Log.info("   Device ID:    \(savedDeviceId?.prefix(16) ?? "MISSING")...", category: "Registration")
            Log.info("   User ID:      \(registerData.userId.prefix(8))...", category: "Registration")
            Log.info("   Username:     \(username ?? "anonymous")", category: "Registration")
            Log.info("   Keychain:     \(keychainOK ? "✅" : "❌")", category: "Registration")
            Log.info("   Session:      \(savedAccessToken != nil ? "✅" : "❌")", category: "Registration")
            Log.info("   AuthViewModel: \(authViewModel.isAuthenticated ? "✅" : "❌")", category: "Registration")
            Log.info("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", category: "Registration")
            
            if keychainOK && savedAccessToken != nil && authViewModel.isAuthenticated {
                Log.info("ALL CHECKS PASSED - Ready for main app!", category: "Registration")
            } else {
                Log.error("SOME CHECKS FAILED - App may not work correctly", category: "Registration")
            }
            
        } catch {
            Log.error("Registration failed: \(error)", category: "Registration")
            currentStep = .error(error.userFacingMessage)
        }
    }
}

// MARK: - Pending bundle persistence
// Delegates to PendingRegistrationStore — public-key-only data stored in UserDefaults.

private extension RegistrationFlowView {
    static func saveBundle(_ bundle: RegistrationBundleFields) {
        PendingRegistrationStore.save(
            identityPublic: Data(bundle.identityPublic),
            signedPrekeyPublic: Data(bundle.signedPrekeyPublic),
            signature: Data(bundle.signature),
            verifyingKey: Data(bundle.verifyingKey),
            suiteId: bundle.suiteId
        )
    }

    static func loadSavedBundle() -> RegistrationBundleFields? {
        guard let t = PendingRegistrationStore.load() else { return nil }
        return RegistrationBundleFields(
            identityPublic: [UInt8](t.identityPublic),
            signedPrekeyPublic: [UInt8](t.signedPrekeyPublic),
            signature: [UInt8](t.signature),
            verifyingKey: [UInt8](t.verifyingKey),
            suiteId: t.suiteId
        )
    }

    static func clearSavedBundle() {
        PendingRegistrationStore.clear()
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
