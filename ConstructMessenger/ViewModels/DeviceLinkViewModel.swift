//
//  DeviceLinkViewModel.swift
//  Construct Messenger
//
//  Handles QR-based device linking.
//
//  Device A (initiator): generates a link token → shows QR code.
//  Device B (new device): scans QR → confirms link → receives JWT → uploads prekeys.
//

import Foundation
import Observation
import GRPCCore

@MainActor
@Observable
final class DeviceLinkViewModel {

    // MARK: - State (Device A)

    /// QR content to display: "konstruct://link?token=<linkToken>&fp=<hex>&s=<hex>"
    var qrContent: String? = nil
    /// When the current link token expires.
    var tokenExpiresAt: Date? = nil
    var isGenerating: Bool = false

    // MARK: - State (Device B)

    var isLinking: Bool = false
    /// Set when link handshake completes — views forward to AuthViewModel.completeDeviceLink.
    var linkOutcome: DeviceLinkOutcome? = nil

    // MARK: - Shared error state

    var errorMessage: String? = nil

    // MARK: - State (New Device → Join Request flow)

    /// QR content encoding this device's join request, e.g.:
    /// "konstruct://link-to-me?id=<deviceId>&pubkey=<base64>&fp=<hex>&name=<name>&platform=<platform>"
    var joinRequestQRContent: String? = nil
    /// True while the new device is waiting for the existing device to approve the join request.
    var isWaitingForApproval: Bool = false
    /// Set by the phone when it scans a "link-to-me" QR — triggers confirmation dialog in the view.
    var pendingApproval: PendingApprovalInfo? = nil
    /// Flow B: pending_device_id the phone just approved (for auto history-sync pairing).
    private(set) var approvedJoinPendingId: String? = nil

    /// What the new device's QR says.
    struct PendingApprovalInfo {
        let deviceId: String
        let identityPublic: Data
        /// Nil: a client older than device certificates.
        let fingerprint: Data?
        let deviceName: String
    }

    private var pollingTask: Task<Void, Never>? = nil
    private var joinDeviceId: String? = nil

    // MARK: - Device A: Generate QR

    /// Calls InitiateDeviceLink on the server and populates `qrContent`.
    func generateLinkCode() async {
        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }

        do {
            let result = try await AuthServiceClient.shared.initiateDeviceLink()
            var fingerprint: Data?
            if let identity = try? CryptoManager.shared.localBundlePublicKeys().identityPublic,
               let hybrid = CryptoManager.shared.hybridIdentityPublicKey(),
               !hybrid.isEmpty {
                fingerprint = historyQrFingerprint(identityPublic: identity, hybridPublic: hybrid)
            }
            // The secret the new device proves its keys under, so this device can vouch for them
            // (device certificates). It is in the QR and nowhere else — never sent to the server.
            let linkSecret = newDeviceLinkSecret()
            let url = try deviceLinkOfferQr(token: result.token, fingerprint: fingerprint, secret: linkSecret)
            DeviceCertificateIssuer.shared.awaitLink(token: result.token, secret: linkSecret)
            qrContent = url
            tokenExpiresAt = Date(timeIntervalSince1970: TimeInterval(result.expiresAt))
            Log.info("Device link QR generated — expires \(result.expiresAt)", category: "DeviceLink")
            #if DEBUG
            // The QR is the only place this token is shown, and a simulator has no camera — so on
            // a DEBUG build it also goes to the log, where `scripts/two_sims.sh link` reads it and
            // pastes it into the other simulator's scanner. Release builds never print it: it
            // authorises joining this account, and the log is exportable from Settings.
            // Beta is Release + DEBUG and runs on testers' phones, whose logs they export: the
            // token goes to the log on a simulator only, where the stand needs it.
            #if targetEnvironment(simulator)
            Log.debug("DeviceLink stand token: \(url)", category: "DeviceLink")
            #endif
            #endif
        } catch {
            errorMessage = localizedError(error)
            Log.error("initiateDeviceLink failed: \(error)", category: "DeviceLink")
        }
    }

    /// True when the link token is still valid.
    var isTokenValid: Bool {
        guard let exp = tokenExpiresAt else { return false }
        return exp > Date()
    }

    // MARK: - Device B: Scan and confirm

    /// A scanned code: the account's device offering to link us, or a new device asking to join.
    func scanAndLink(scannedURL: String) async {
        switch readDeviceLinkQr(text: scannedURL) {
        case .joinRequest(let deviceId, let identityPublic, let fingerprint, let name, _):
            // Surface a confirmation dialog in the view.
            pendingApproval = PendingApprovalInfo(
                deviceId: deviceId, identityPublic: identityPublic, fingerprint: fingerprint, deviceName: name
            )
        case .offer(let token, let fingerprint, let secret):
            if let fingerprint {
                DeviceLinkPendingPin.store(fingerprint, forToken: token)
            }
            await confirmLink(token: token, linkSecret: secret)
        case nil:
            errorMessage = NSLocalizedString("device_link_invalid_qr", comment: "")
        }
    }

    /// Called when Device B has a raw link token (e.g. from deep link). `linkSecret`: the `s` of
    /// the old device's QR — without it the old device cannot vouch for this one, and its peers
    /// see an unvouched device.
    func confirmLink(token: String, linkSecret: Data? = nil) async {
        isLinking = true
        errorMessage = nil
        defer { isLinking = false }

        do {
            CryptoManager.shared.prepareForDeviceLink()
            KeychainManager.shared.deleteDeviceKeys()
            let (deviceId, bundle) = try CryptoManager.shared.generateRegistrationBundle()
            KeychainManager.shared.saveDeviceID(deviceId)
            let linkIdentity = try CryptoManager.shared.prepareLinkIdentity(linkSecret: linkSecret)

            var publicKeys = Shared_Proto_Services_V1_DevicePublicKeys()
            publicKeys.verifyingKey = bundle.verifyingKey
            publicKeys.identityPublic = bundle.identityPublic
            publicKeys.signedPrekeyPublic = bundle.signedPrekeyPublic
            publicKeys.signedPrekeySignature = bundle.signature
            publicKeys.cryptoSuite = "Curve25519+Ed25519"

            Log.info("Device B: generated deviceId=\(deviceId) for link confirmation", category: "DeviceLink")

            // 2. Confirm device link — receives JWT
            let result = try await AuthServiceClient.shared.confirmDeviceLink(
                linkToken: token,
                deviceId: deviceId,
                publicKeys: publicKeys,
                linkKeyProof: linkIdentity.keyProof ?? Data()
            )

            Log.info("Device B: link confirmed — userId=\(result.userId.prefix(8))…", category: "DeviceLink")

            await finishLink(
                result: result,
                deviceId: deviceId,
                role: .linkedNewDevice,
                pendingDeviceId: nil
            )
            DeviceLinkPendingPin.bindToAccount(userId: result.userId, fromToken: token)

        } catch {
            errorMessage = localizedError(error)
            Log.error("confirmDeviceLink failed: \(error)", category: "DeviceLink")
        }
    }

    // MARK: - Private helpers

    // MARK: - New Device Join Request (Desktop onboarding — laptop shows QR for phone to scan)

    /// A join request deletes this device's keys and makes new ones, so it may start only on a
    /// device that holds no account. On macOS 15 the onboarding sheets were built again after
    /// `completeDeviceLink` signed the device in, and the new screen's `.task` started a second
    /// request: the keys the phone had just approved were deleted, and the Mac was left as a
    /// device its account does not have (tester log 2026-10-29, Intel Mac on macOS 15.8).
    nonisolated static func joinRequestMayStart(isAuthenticated: Bool) -> Bool {
        !isAuthenticated
    }

    /// Generates a one-time key pair and encodes a "join request" QR.
    /// The phone scans this and calls `approveJoinRequest` to approve.
    func generateJoinRequestQR(isAuthenticated: Bool) async {
        guard Self.joinRequestMayStart(isAuthenticated: isAuthenticated) else {
            Log.error("generateJoinRequestQR refused: this device is already signed in", category: "DeviceLink")
            return
        }
        isGenerating = true
        errorMessage = nil
        joinRequestQRContent = nil
        defer { isGenerating = false }
        do {
            CryptoManager.shared.prepareForDeviceLink()
            KeychainManager.shared.deleteDeviceKeys()
            let (deviceId, bundle) = try CryptoManager.shared.generateRegistrationBundle()
            joinDeviceId = deviceId
            KeychainManager.shared.saveDeviceID(deviceId)
            // The phone vouches for exactly the keys this fingerprint names, the hybrid key
            // included — so the key exists, and is saved, before the QR does.
            let linkIdentity = try CryptoManager.shared.prepareLinkIdentity(linkSecret: nil)
            let name = DeviceInfo.deviceName
            let platform = platformString()
            let url = try deviceJoinRequestQr(
                identityPublic: linkIdentity.identityPublic,
                hybridPublic: linkIdentity.hybridPublic,
                name: name,
                platform: platform
            )

            try await AuthServiceClient.shared.submitJoinRequest(
                deviceId: deviceId,
                bundle: bundle,
                deviceName: name,
                platform: platform
            )
            Log.info("Join request submitted to server — deviceId=\(deviceId.prefix(8))…", category: "DeviceLink")

            joinRequestQRContent = url
            #if DEBUG
            // Same reason as the Flow A token above: a simulator phone cannot scan this Mac's QR,
            // so `scripts/history_stand.sh` reads it here. It names a device and its public key and
            // grants nothing — the phone's approval does.
            Log.info("DeviceLink stand join request: \(url)", category: "DeviceLink")
            #endif
            isWaitingForApproval = true
            startPollingForApproval(pendingId: deviceId)
            Log.info("Join request QR generated — deviceId=\(deviceId.prefix(8))…", category: "DeviceLink")
        } catch {
            errorMessage = localizedError(error)
            Log.error("generateJoinRequestQR failed: \(error)", category: "DeviceLink")
        }
    }

    func cancelPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        isWaitingForApproval = false
    }

    private func startPollingForApproval(pendingId: String) {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            guard let self else { return }
            let join = DeviceJoin(
                status: { try await AuthServiceClient.shared.joinRequestStatus(pendingId: pendingId) },
                signIn: { try await AuthServiceClient.shared.signInAsJoinedDevice(deviceId: pendingId) }
            )
            // Cancelled: whoever cancelled has cleared the screen.
            guard let outcome = try? await join.run() else { return }
            self.isWaitingForApproval = false
            switch outcome {
            case .signedIn(let result):
                let deviceId = self.joinDeviceId ?? pendingId
                // The keys are already in the key record `generateRegistrationBundle` saved.
                KeychainManager.shared.saveDeviceID(deviceId)
                await self.finishLink(
                    result: result,
                    deviceId: deviceId,
                    role: .linkedNewDevice,
                    pendingDeviceId: pendingId
                )
                // Flow B: we showed the QR, so nothing pins the offering device on this
                // side. Recorded so the history verifier can tell it from a Flow A QR
                // without `fp`, which refuses.
                DeviceLinkPendingPin.markBundleOnly(userId: result.userId)
            case .ended(let end):
                Log.error("join request ended: \(end)", category: "DeviceLink")
                self.errorMessage = DeviceLinkError(end).errorDescription
            }
        }
    }

    // MARK: - Phone: Approve a new device's join request

    /// Called by the phone when it scans the Desktop's "link-to-me" QR and the user confirms.
    func approveJoinRequest(_ request: PendingApprovalInfo) async {
        let pendingId = request.deviceId
        isLinking = true
        errorMessage = nil
        defer { isLinking = false }
        do {
            try await AuthServiceClient.shared.approveDeviceJoinRequest(pendingId: pendingId)
            approvedJoinPendingId = pendingId
            // A device joined our set: the cached own-device list is now one short.
            MultiDeviceSendCoordinator.shared.invalidateOwnDeviceCache()
            // Flow B: the QR is the one out-of-band channel; the history sender checks the
            // new device's bundle identity against it (`qr_pin_mismatch`), not the directory alone.
            DeviceLinkPendingPin.storePeerIdentity(request.identityPublic, forDeviceId: pendingId)
            // The QR's `fp` names the new device's keys, its hybrid key included; the core signs
            // them only if the directory serves exactly those. A QR without it (a client older than
            // device certificates) leaves the device unvouched.
            if let fp = request.fingerprint {
                DeviceCertificateIssuer.shared.vouch(deviceId: pendingId, evidence: .qrFingerprint(fp))
            } else {
                Log.info("device_cert device=\(pendingId.prefix(8))… QR names no fingerprint — not vouched", category: "DeviceLink")
            }
            if let userId = KeychainManager.shared.loadUserID() {
                linkOutcome = DeviceLinkOutcome(
                    role: .approvedJoinRequest,
                    userId: userId,
                    deviceId: KeychainManager.shared.loadDeviceID() ?? "",
                    pendingDeviceId: pendingId
                )
            }
            Log.info("Approved join request for '\(request.deviceName)' (id=\(pendingId.prefix(8))…)", category: "DeviceLink")
        } catch {
            errorMessage = localizedError(error)
            Log.error("approveJoinRequest failed: \(error)", category: "DeviceLink")
        }
    }

    private func platformString() -> String {
        #if os(iOS)
        return "ios"
        #else
        return "desktop"
        #endif
    }

    // MARK: - Private helpers

    /// Persists session tokens (with expiry + GRPC cache sync), initializes crypto, uploads OTPKs.
    private func finishLink(
        result: AuthServiceClient.ConfirmLinkResult,
        deviceId: String,
        role: DeviceLinkOutcome.Role,
        pendingDeviceId: String?
    ) async {
        let expiresIn = max(Int(result.expiresAt - Int64(Date().timeIntervalSince1970)), 0)

        AuthSessionManager.shared.saveTokens(
            accessToken: result.accessToken,
            refreshToken: result.refreshToken,
            expiresIn: expiresIn,
            userId: result.userId
        )
        // Unconditional: live mail must not replay pre-link ciphertext into empty
        // ratchets, whether or not the history offer is shown. Must not roll back
        // with the policy flag.
        if role == .linkedNewDevice {
            DeviceLinkStreamCursorPolicy.applyAccountOnlyCheckpoint(accessToken: result.accessToken)
        }
        VeilProxyManager.shared.configureFromServer(cert: result.veilBridgeCert ?? "")

        CryptoManager.shared.resetOrchestratorStateForDeviceLink()
        CryptoManager.shared.setLocalUserId(result.userId)
        await uploadPreKeysAfterLink(deviceId: deviceId)
        PreKeyRotationService.shared.recordSpkUpload()

        linkOutcome = DeviceLinkOutcome(
            role: role,
            userId: result.userId,
            deviceId: deviceId,
            pendingDeviceId: pendingDeviceId
        )
    }

    private func uploadPreKeysAfterLink(deviceId: String) async {
        do {
            let count = try await OtpkReplenishmentService.generateAndUpload(
                count: 100,
                deviceId: deviceId,
                replaceExisting: true
            )
            Log.info("Device B: uploaded \(count) OTPKs after link", category: "DeviceLink")
        } catch {
            Log.error("Device B: OTPK upload failed (non-fatal): \(error)", category: "DeviceLink")
        }
    }

    private func localizedError(_ error: Error) -> String {
        if let grpcError = error as? RPCError {
            switch grpcError.code {
            case .unauthenticated: return UserText("device_link_error_token").resolved
            case .alreadyExists:   return UserText("device_link_error_already_linked").resolved
            default:               break
            }
        }
        // Everything else — a timeout, the rate limit, an error of ours — through the one set.
        return error.userFacingMessage
    }
}

// MARK: - DeviceLinkError

enum DeviceLinkError: LocalizedError, UserFacingError {
    case keyGenerationFailed
    case invalidQRCode
    case rejected
    case expired
    case signInRefused
    case letInUnreachable

    var userText: UserText {
        switch self {
        case .keyGenerationFailed: return UserText("device_link_error_keys")
        case .invalidQRCode:       return UserText("device_link_error_invalid_qr")
        case .rejected:            return UserText("device_link_error_rejected")
        case .expired:             return UserText("device_link_error_expired")
        case .signInRefused:       return UserText("device_link_error_sign_in_refused")
        case .letInUnreachable:    return UserText("device_link_error_let_in_unreachable")
        }
    }

    var errorDescription: String? { userText.resolved }
}
