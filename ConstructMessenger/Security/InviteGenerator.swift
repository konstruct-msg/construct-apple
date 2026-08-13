//
//  InviteGenerator.swift
//  Construct Messenger
//
//  Created by Copilot on 29.01.2026.
//

import Foundation

/// Generator for cryptographically secure one-time invite links
///
/// Usage:
/// ```swift
/// let generator = InviteGenerator()
/// let invite = try generator.generate(
///     userId: "user-uuid",
///     serverFQDN: "konstruct.cc"
/// )
/// ```
class InviteGenerator {
    
    // MARK: - Configuration
    
    /// Default server FQDN
    /// Can be overridden per invite
    private let defaultServer: String
    
    init(defaultServer: String = "konstruct.cc") {
        self.defaultServer = defaultServer
    }
    
    // MARK: - Generation
    
    /// Generate a new invite object (protocol v4: signed capability, no dead ephKey).
    ///
    /// Process:
    /// 1. Create JTI (UUIDv4)
    /// 2. Build invite data structure (no ephemeral keypair)
    /// 3. Sign with user's Ed25519 identity key
    ///
    /// - Parameters:
    ///   - userId: Sender's user UUID (for chat creation)
    ///   - deviceId: Sender's device ID (for fetching keys)
    ///   - username: Optional plaintext @alias in the signed payload. **Default nil**
    ///     (metadata minimization). Never pass for HTTPS deep links.
    ///   - serverFQDN: Server FQDN (optional, uses default if nil)
    /// - Returns: Signed InviteObject
    /// - Throws: InviteGenerationError
    func generate(
        userId: String,
        deviceId: String,
        username: String? = nil,
        serverFQDN: String? = nil
    ) throws -> InviteObject {
        guard UUID(uuidString: userId) != nil else {
            throw InviteGenerationError.invalidUserId
        }
        guard deviceId.count == InviteConfig.deviceIdLength,
              deviceId.range(of: InviteConfig.deviceIdRegex, options: .regularExpression) != nil else {
            throw InviteGenerationError.invalidDeviceId
        }

        let server = normalizeServer(serverFQDN ?? defaultServer)
        let jti = UUID().uuidString.lowercased()
        let timestamp = Int(Date().timeIntervalSince1970)

        guard let signingSecretKey = try? getSigningSecretKey() else {
            throw InviteGenerationError.missingIdentityKey
        }

        let normalizedUsername = username
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }

        // v4: empty ephKey — pure signed capability (F2).
        let unsignedInvite = InviteObject(
            v: InviteConfig.currentVersion,
            jti: jti,
            uuid: userId.lowercased(),
            deviceId: deviceId,
            server: server,
            ephKey: "",
            ts: timestamp,
            sig: "",
            un: normalizedUsername
        )

        let dataToSign = unsignedInvite.canonicalString()
        Log.debug("Canonical string for signing: \(dataToSign)", category: "InviteGenerator")

        let expectedVerifyingKey = try deriveVerifyingKeyFromSecret(identitySecretKey: signingSecretKey)
        let signature = try signInviteData(
            data: dataToSign,
            identitySecretKey: signingSecretKey
        )

        let isSelfValid = try verifyInviteSignature(
            data: dataToSign,
            signature: [UInt8](signature.signature),
            verifyingKey: [UInt8](expectedVerifyingKey)
        )
        if !isSelfValid {
            Log.error("Invite self-verify failed (signing key mismatch)", category: "InviteGenerator")
            throw InviteGenerationError.signingFailed
        }

        let signatureBase64 = Data(signature.signature).base64EncodedString()
        let signedInvite = InviteObject(
            v: InviteConfig.currentVersion,
            jti: jti,
            uuid: userId.lowercased(),
            deviceId: deviceId,
            server: server,
            ephKey: "",
            ts: timestamp,
            sig: signatureBase64,
            un: normalizedUsername
        )

        try signedInvite.validate()

        let ttlMinutes = Int(InviteConfig.ttlSeconds / 60)
        Log.info(
            "Generated invite v\(InviteConfig.currentVersion): jti=\(jti.prefix(8))..., expires in \(ttlMinutes) min",
            category: "InviteGenerator"
        )
        return signedInvite
    }
    
    // MARK: - QR Code & Link Generation

    /// Generate compact binary payload for QR **byte mode** (no base64).
    ///
    /// Smaller than legacy base64(JSON) deep links; pair with `QRCodeGenerator.generate(from:)`.
    func generateQRBinary(
        userId: String,
        deviceId: String,
        username: String? = nil,
        server: String? = nil
    ) throws -> Data {
        let invite = try generate(
            userId: userId,
            deviceId: deviceId,
            username: username,
            serverFQDN: normalizeServer(server ?? defaultServer)
        )
        return try invite.encodeBinary()
    }

    /// Generate text-safe payload for clipboard / base64-like QR fallbacks.
    /// base64url over compact binary (not JSON).
    func generateQRPayload(
        userId: String,
        deviceId: String,
        username: String? = nil,
        server: String? = nil
    ) throws -> String {
        let binary = try generateQRBinary(
            userId: userId,
            deviceId: deviceId,
            username: username,
            server: server
        )
        return InviteBinaryCodec.base64URLEncode(binary)
    }

    /// Generate deep link URL for sharing
    ///
    /// Format: `konstruct://add?invite=<base64url>`
    /// Also supports: `https://konstruct.cc/add?invite=<base64url>`
    ///
    /// The invite query value is base64url(compact binary) — URLs are a text boundary.
    func generateDeepLink(
        userId: String,
        deviceId: String,
        username: String? = nil,
        server: String? = nil,
        useHTTPS: Bool = false
    ) throws -> String {
        let normalizedServer = normalizeServer(server ?? defaultServer)
        let payload = try generateQRPayload(
            userId: userId,
            deviceId: deviceId,
            username: username,
            server: normalizedServer
        )

        if useHTTPS {
            return "https://\(normalizedServer)/add?invite=\(payload)"
        } else {
            return "konstruct://add?invite=\(payload)"
        }
    }
    
    // MARK: - Helper Methods
    
    /// Get Ed25519 signing secret key from CryptoManager
    /// - Returns: 32-byte signing secret key
    /// - Throws: InviteGenerationError if key not available
    private func getSigningSecretKey() throws -> [UInt8] {
        guard let core = CryptoManager.shared.orchestratorCore else {
            throw InviteGenerationError.missingIdentityKey
        }
        let keyBytes = try core.getSigningKeyBytes()
        guard !keyBytes.isEmpty else {
            throw InviteGenerationError.keyDecodingFailed
        }
        Log.debug("Using signing secret key for invite signing (\(keyBytes.count) bytes)", category: "InviteGenerator")
        return [UInt8](keyBytes)
    }

    /// Derive the expected verifying key (Base64) from local signing secret.
    func expectedVerifyingKeyBase64() throws -> String {
        let signingSecretKey = try getSigningSecretKey()
        let verifyingKey = try deriveVerifyingKeyFromSecret(identitySecretKey: signingSecretKey)
        return Data(verifyingKey).base64EncodedString()
    }

    // MARK: - Server Normalization

    /// Normalize server input to host-only (no scheme, no trailing slash)
    private func normalizeServer(_ server: String) -> String {
        var value = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("http://") {
            value = String(value.dropFirst("http://".count))
        } else if value.hasPrefix("https://") {
            value = String(value.dropFirst("https://".count))
        }
        if value.hasSuffix("/") {
            value = String(value.dropLast())
        }
        return value
    }
    
    // MARK: - Private Keys JSON Structure
    
}

// MARK: - Errors

enum InviteGenerationError: LocalizedError {
    case invalidUserId
    case invalidDeviceId
    case missingIdentityKey
    case keyDecodingFailed
    case ephemeralKeyGenerationFailed
    case signingFailed
    
    var errorDescription: String? {
        switch self {
        case .invalidUserId:
            return "Invalid user ID (must be UUIDv4)"
        case .invalidDeviceId:
            return "Invalid device ID (must be 32-char hex)"
        case .missingIdentityKey:
            return "Identity key not available. User may not be logged in."
        case .keyDecodingFailed:
            return "Failed to decode cryptographic keys"
        case .ephemeralKeyGenerationFailed:
            return "Failed to generate ephemeral keypair"
        case .signingFailed:
            return "Failed to sign invite data"
        }
    }
}
