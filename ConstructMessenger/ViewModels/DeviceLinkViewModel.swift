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
            Log.info("📱 Device link QR generated — expires \(result.expiresAt)", category: "DeviceLink")
        } catch {
            errorMessage = localizedError(error)
            Log.error("❌ initiateDeviceLink failed: \(error)", category: "DeviceLink")
        }
    }

    /// True when the link token is still valid.
    var isTokenValid: Bool {
        guard let exp = tokenExpiresAt else { return false }
        return exp > Date()
    }

    // MARK: - Device B: Scan and confirm

    /// Called when Device B has scanned the QR code.
    /// Generates fresh keys, calls ConfirmDeviceLink, saves JWT, uploads prekeys.
    /// - Parameter scannedURL: Full URL string from QR, e.g. "konstruct://link?token=..."
    func scanAndLink(scannedURL: String) async {
        guard let token = extractToken(from: scannedURL), !token.isEmpty else {
            errorMessage = "Invalid QR code format"
            return
        }
        await confirmLink(token: token)
    }

    /// Called when Device B has a raw link token (e.g. from deep link).
    func confirmLink(token: String) async {
        isLinking = true
        errorMessage = nil
        defer { isLinking = false }

        do {
            // 1. Generate fresh keys for this new device
            let (deviceId, bundleJson, _, _) = try CryptoManager.shared.generateRegistrationBundle()

            guard let bundleData = bundleJson.data(using: .utf8),
                  let bundleDict = try? JSONSerialization.jsonObject(with: bundleData) as? [String: Any] else {
                throw DeviceLinkError.keyGenerationFailed
            }

            let spkSig = (bundleDict["signed_prekey_signature"] as? String)
                ?? (bundleDict["signature"] as? String) ?? ""

            var publicKeys = Shared_Proto_Services_V1_DevicePublicKeys()
            publicKeys.verifyingKey = bundleDict["verifying_key"] as? String ?? ""
            publicKeys.identityPublic = bundleDict["identity_public"] as? String ?? ""
            publicKeys.signedPrekeyPublic = bundleDict["signed_prekey_public"] as? String ?? ""
            publicKeys.signedPrekeySignature = spkSig
            publicKeys.cryptoSuite = "Curve25519+Ed25519"

            Log.info("🔑 Device B: generated deviceId=\(deviceId) for link confirmation", category: "DeviceLink")

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

            Log.info("✅ Device B: link confirmed — userId=\(result.userId.prefix(8))…", category: "DeviceLink")

            // 4. Upload OTPKs (required — senders get "no prekeys" without this)
            await uploadPreKeysAfterLink(deviceId: deviceId)

            linkCompleted = true

        } catch {
            errorMessage = localizedError(error)
            Log.error("❌ confirmDeviceLink failed: \(error)", category: "DeviceLink")
        }
    }

    // MARK: - Private helpers

    private func uploadPreKeysAfterLink(deviceId: String) async {
        do {
            let count = try await OtpkReplenishmentService.generateAndUpload(
                count: 100,
                deviceId: deviceId,
                replaceExisting: true
            )
            Log.info("📦 Device B: uploaded \(count) OTPKs after link", category: "DeviceLink")
        } catch {
            Log.error("⚠️ Device B: OTPK upload failed (non-fatal): \(error)", category: "DeviceLink")
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

    var errorDescription: String? {
        switch self {
        case .keyGenerationFailed: return "Failed to generate device keys — please try again"
        case .invalidQRCode: return "Could not read QR code — make sure it's a valid Construct link"
        }
    }
}
