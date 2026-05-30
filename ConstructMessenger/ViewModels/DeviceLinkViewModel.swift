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

    /// QR content to display: "konstruct://link?token=<linkToken>"
    var qrContent: String? = nil
    /// When the current link token expires.
    var tokenExpiresAt: Date? = nil
    var isGenerating: Bool = false

    // MARK: - State (Device B)

    var isLinking: Bool = false
    /// Set to true on successful link completion (triggers navigation).
    var linkCompleted: Bool = false

    // MARK: - Shared error state

    var errorMessage: String? = nil

    // MARK: - State (New Device → Join Request flow)

    /// QR content encoding this device's join request, e.g.:
    /// "konstruct://link-to-me?id=<deviceId>&pubkey=<base64>&name=<name>&platform=<platform>"
    var joinRequestQRContent: String? = nil
    /// True while the new device is waiting for the existing device to approve the join request.
    var isWaitingForApproval: Bool = false
    /// Set by the phone when it scans a "link-to-me" QR — triggers confirmation dialog in the view.
    var pendingApproval: PendingApprovalInfo? = nil
    /// True when the phone has successfully approved a join request (phone side only).
    var approvalGranted: Bool = false

    struct PendingApprovalInfo {
        let deviceName: String
        let scannedURL: String
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
            let url = "konstruct://link?token=\(result.token)"
            qrContent = url
            tokenExpiresAt = Date(timeIntervalSince1970: TimeInterval(result.expiresAt))
            Log.info("Device link QR generated — expires \(result.expiresAt)", category: "DeviceLink")
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

    /// Updated scanAndLink — dispatches based on URL scheme.
    func scanAndLink(scannedURL: String) async {
        if scannedURL.hasPrefix("konstruct://link-to-me") {
            // Parse join request and surface a confirmation dialog in the view.
            guard let components = URLComponents(string: scannedURL),
                  let name = components.queryItems?
                      .first(where: { $0.name == "name" })?.value?
                      .removingPercentEncoding
            else {
                errorMessage = NSLocalizedString("device_link_invalid_qr", comment: "")
                return
            }
            pendingApproval = PendingApprovalInfo(deviceName: name, scannedURL: scannedURL)
        } else if let token = extractToken(from: scannedURL), !token.isEmpty {
            await confirmLink(token: token)
        } else {
            errorMessage = NSLocalizedString("device_link_invalid_qr", comment: "")
        }
    }

    /// Called when Device B has a raw link token (e.g. from deep link).
    func confirmLink(token: String) async {
        isLinking = true
        errorMessage = nil
        defer { isLinking = false }

        do {
            // 1. Generate fresh keys for this new device
            let (deviceId, bundle, _, _) = try CryptoManager.shared.generateRegistrationBundle()

            var publicKeys = Shared_Proto_Services_V1_DevicePublicKeys()
            publicKeys.verifyingKey = Data(bundle.verifyingKey)
            publicKeys.identityPublic = Data(bundle.identityPublic)
            publicKeys.signedPrekeyPublic = Data(bundle.signedPrekeyPublic)
            publicKeys.signedPrekeySignature = Data(bundle.signature)
            publicKeys.cryptoSuite = "Curve25519+Ed25519"

            Log.info("Device B: generated deviceId=\(deviceId) for link confirmation", category: "DeviceLink")

            // 2. Confirm device link — receives JWT
            let result = try await AuthServiceClient.shared.confirmDeviceLink(
                linkToken: token,
                deviceId: deviceId,
                publicKeys: publicKeys
            )

            // 3. Persist credentials
            KeychainManager.shared.saveDeviceID(deviceId)
            KeychainManager.shared.saveUserID(result.userId)
            KeychainManager.shared.saveSessionToken(result.accessToken)
            KeychainManager.shared.saveRefreshToken(result.refreshToken)
            if let cert = result.iceBridgeCert, !cert.isEmpty {
                KeychainManager.shared.saveIceBridgeCert(cert)
            }

            Log.info("Device B: link confirmed — userId=\(result.userId.prefix(8))…", category: "DeviceLink")

            // 4. Upload OTPKs (required — senders get "no prekeys" without this)
            await uploadPreKeysAfterLink(deviceId: deviceId)

            linkCompleted = true

        } catch {
            errorMessage = localizedError(error)
            Log.error("confirmDeviceLink failed: \(error)", category: "DeviceLink")
        }
    }

    // MARK: - Private helpers

    // MARK: - New Device Join Request (Desktop onboarding — laptop shows QR for phone to scan)

    /// Generates a one-time key pair and encodes a "join request" QR.
    /// The phone scans this and calls `approveJoinRequest(from:)` to approve.
    func generateJoinRequestQR() async {
        isGenerating = true
        errorMessage = nil
        joinRequestQRContent = nil
        defer { isGenerating = false }
        do {
            let (deviceId, bundle, _, _) = try CryptoManager.shared.generateRegistrationBundle()
            joinDeviceId = deviceId
            let name = DeviceInfo.deviceName
            let platform = platformString()
            let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
            let url = "konstruct://link-to-me?id=\(deviceId)&pubkey=\(bundle.identityPublic)&name=\(encoded)&platform=\(platform)"

            joinRequestQRContent = url
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
            let deadline = Date().addingTimeInterval(10 * 60) // 10 min
            while Date() < deadline, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { break }
                do {
                    if let result = try await AuthServiceClient.shared.checkDeviceLinkStatus(pendingId: pendingId) {
                        let deviceId = self.joinDeviceId ?? pendingId
                        KeychainManager.shared.saveDeviceID(deviceId)
                        KeychainManager.shared.saveUserID(result.userId)
                        KeychainManager.shared.saveSessionToken(result.accessToken)
                        KeychainManager.shared.saveRefreshToken(result.refreshToken)
                        if let cert = result.iceBridgeCert, !cert.isEmpty {
                            KeychainManager.shared.saveIceBridgeCert(cert)
                        }
                        await uploadPreKeysAfterLink(deviceId: deviceId)
                        self.isWaitingForApproval = false
                        self.linkCompleted = true
                        break
                    }
                } catch DeviceLinkError.rejected {
                    self.isWaitingForApproval = false
                    self.errorMessage = DeviceLinkError.rejected.errorDescription
                    break
                } catch DeviceLinkError.expired {
                    self.isWaitingForApproval = false
                    self.errorMessage = DeviceLinkError.expired.errorDescription
                    break
                } catch {
                    // Transient network error — keep polling
                    Log.debug("checkDeviceLinkStatus polling: \(error)", category: "DeviceLink")
                }
            }
            if !self.linkCompleted {
                self.isWaitingForApproval = false
            }
        }
    }

    // MARK: - Phone: Approve a new device's join request

    /// Called by the phone when it scans the Desktop's "link-to-me" QR and the user confirms.
    func approveJoinRequest(from scannedURL: String) async {
        guard let components = URLComponents(string: scannedURL),
              let pendingId  = components.queryItems?.first(where: { $0.name == "id" })?.value,
              let pubkey     = components.queryItems?.first(where: { $0.name == "pubkey" })?.value,
              let name       = components.queryItems?.first(where: { $0.name == "name" })?.value?.removingPercentEncoding,
              let platform   = components.queryItems?.first(where: { $0.name == "platform" })?.value
        else {
            errorMessage = NSLocalizedString("device_link_invalid_qr", comment: "")
            return
        }
        isLinking = true
        errorMessage = nil
        defer { isLinking = false }
        do {
            try await AuthServiceClient.shared.approveDeviceJoinRequest(
                pendingId: pendingId,
                newDeviceId: pendingId,
                newDevicePublicKey: pubkey,
                newDeviceName: name,
                newDevicePlatform: platform
            )
            approvalGranted = true
            Log.info("Approved join request for '\(name)' (id=\(pendingId.prefix(8))…)", category: "DeviceLink")
        } catch {
            errorMessage = localizedError(error)
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

    private func extractToken(from url: String) -> String? {
        guard let components = URLComponents(string: url),
              let item = components.queryItems?.first(where: { $0.name == "token" }) else {
            return nil
        }
        return item.value
    }

    private func localizedError(_ error: Error) -> String {
        if let grpcError = error as? RPCError {
            switch grpcError.code {
            case .unauthenticated:
                return "Link token expired or invalid — please scan a fresh QR code"
            case .alreadyExists:
                return "This device is already linked"
            case .resourceExhausted:
                return "Rate limit reached — try again in 24 hours"
            case .deadlineExceeded:
                return "Network timeout — please check your connection and retry"
            default:
                return "Failed: \(grpcError.message)"
            }
        }
        if let deviceLinkError = error as? DeviceLinkError {
            return deviceLinkError.localizedDescription
        }
        return error.localizedDescription
    }
}

// MARK: - DeviceLinkError

enum DeviceLinkError: LocalizedError {
    case keyGenerationFailed
    case invalidQRCode
    case rejected
    case expired

    var errorDescription: String? {
        switch self {
        case .keyGenerationFailed: return "Failed to generate device keys — please try again"
        case .invalidQRCode:       return "Could not read QR code — make sure it's a valid Construct link"
        case .rejected:            return "Device link request was rejected by the existing device"
        case .expired:             return "Device link request expired — please generate a new QR code"
        }
    }
}
