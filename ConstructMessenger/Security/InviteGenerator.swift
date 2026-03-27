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
    
    /// Generate a new invite object
    ///
    /// Process:
    /// 1. Generate fresh ephemeral X25519 keypair
    /// 2. Create JTI (UUIDv4)
    /// 3. Build invite data structure
    /// 4. Sign with user's Ed25519 identity key
    ///
    /// - Parameters:
    ///   - userId: Sender's user UUID (for chat creation)
    ///   - deviceId: Sender's device ID (for fetching keys)
    ///   - serverFQDN: Server FQDN (optional, uses default if nil)
    /// - Returns: Signed InviteObject
    /// - Throws: InviteGenerationError
    func generate(
        userId: String,
        deviceId: String,
        serverFQDN: String? = nil
    ) throws -> InviteObject {
        // Validate inputs
        guard UUID(uuidString: userId) != nil else {
            throw InviteGenerationError.invalidUserId
        }
        guard deviceId.count == InviteConfig.deviceIdLength,
              deviceId.range(of: InviteConfig.deviceIdRegex, options: .regularExpression) != nil else {
            throw InviteGenerationError.invalidDeviceId
        }
        
        let server = normalizeServer(serverFQDN ?? defaultServer)
        
        // Step 1: Generate ephemeral keypair
        let ephemeralKeypair = try generateEphemeralKeypair()
        Log.debug("🔐 Generated ephemeral keypair for invite", category: "InviteGenerator")
        
        // Step 2: Generate JTI
        let jti = UUID().uuidString.lowercased()
        
        // Step 3: Current timestamp
        let timestamp = Int(Date().timeIntervalSince1970)
        
        // Step 4: Encode ephemeral public key to Base64
        let ephKeyBase64 = Data(ephemeralKeypair.publicKey).base64EncodedString()
        
        // Step 5: Get user's identity secret key from CryptoManager
        guard let signingSecretKey = try? getSigningSecretKey() else {
            throw InviteGenerationError.missingIdentityKey
        }
        
        // Step 6: Create unsigned invite
        let unsignedInvite = InviteObject(
            v: InviteConfig.currentVersion,
            jti: jti,
            uuid: userId.lowercased(),
            deviceId: deviceId,
            server: server,
            ephKey: ephKeyBase64,
            ts: timestamp,
            sig: "" // Will be filled after signing
        )
        
        // Step 7: Get canonical string for signing
        let dataToSign = unsignedInvite.canonicalString()
        
        Log.debug("🔐 Canonical string for signing: \(dataToSign)", category: "InviteGenerator")
        
        // Step 8: Sign with identity key
        Log.debug("🔐 SIGN: Calling Rust signInviteData", category: "InviteGenerator")
        Log.debug("   Data bytes: \(dataToSign.utf8.count)", category: "InviteGenerator")
        Log.debug("   Signing secret key bytes: \(signingSecretKey.count)", category: "InviteGenerator")
        
        // ✅ DEBUG: Derive public key from this secret key to verify it matches server
        let expectedVerifyingKey = try deriveVerifyingKeyFromSecret(identitySecretKey: signingSecretKey)
        let expectedVerifyingKeyBase64 = Data(expectedVerifyingKey).base64EncodedString()
        Log.debug("🔐 SIGN: Expected verifying key from our secret: \(expectedVerifyingKeyBase64)", category: "InviteGenerator")
        
        let signature = try signInviteData(
            data: dataToSign,
            identitySecretKey: signingSecretKey
        )
        
        Log.debug("🔐 SIGN: Rust returned signature bytes: \(signature.signature.count)", category: "InviteGenerator")

        // Step 8b: Self-verify signature using derived verifying key (debug safety)
        let isSelfValid = try verifyInviteSignature(
            data: dataToSign,
            signature: [UInt8](signature.signature),
            verifyingKey: [UInt8](expectedVerifyingKey)
        )
        Log.debug("🔐 SIGN: Self-verify result: \(isSelfValid)", category: "InviteGenerator")
        if !isSelfValid {
            Log.error("❌ Invite self-verify failed (signing key mismatch)", category: "InviteGenerator")
            throw InviteGenerationError.signingFailed
        }
        
        // Step 9: Encode signature to Base64
        let signatureBase64 = Data(signature.signature).base64EncodedString()
        
        Log.debug("🔐 Generated signature: \(signatureBase64)", category: "InviteGenerator")
        
        // Step 10: Create final signed invite — use the same lowercased UUID that was signed
        let signedInvite = InviteObject(
            v: InviteConfig.currentVersion,
            jti: jti,
            uuid: userId.lowercased(),
            deviceId: deviceId,
            server: server,
            ephKey: ephKeyBase64,
            ts: timestamp,
            sig: signatureBase64
        )
        
        // Validate before returning
        try signedInvite.validate()
        
        let ttlMinutes = Int(InviteConfig.ttlSeconds / 60)
        Log.info("✅ Generated invite: jti=\(jti.prefix(8))..., expires in \(ttlMinutes) minutes", category: "InviteGenerator")
        
        return signedInvite
    }
    
    // MARK: - QR Code & Link Generation
    
    /// Generate QR code payload (Base64-encoded MessagePack)
    ///
    /// This is the optimized format for QR codes:
    /// - MessagePack encoding: 35% smaller than JSON
    /// - Base64: Safe for QR code encoding
    /// - Result: QR Version 9 instead of 10 (easier to scan)
    ///
    /// - Parameters:
    ///   - userId: Current user's UUID
    ///   - deviceId: Current device ID
    ///   - server: Server FQDN (optional, uses default)
    /// - Returns: Base64 string ready for QR code
    /// - Throws: InviteGenerationError or EncodingError
    func generateQRPayload(userId: String, deviceId: String, server: String? = nil) throws -> String {
        let invite = try generate(userId: userId, deviceId: deviceId, serverFQDN: normalizeServer(server ?? defaultServer))
        return try invite.toBase64()
    }
    
    /// Generate deep link URL for sharing
    ///
    /// Format: `konstruct://add?invite=<base64>`
    /// Also supports: `https://konstruct.cc/add?invite=<base64>`
    ///
    /// - Parameters:
    ///   - userId: Current user's UUID
    ///   - deviceId: Current device ID
    ///   - server: Server FQDN (optional, uses default)
    ///   - useHTTPS: Use HTTPS URL instead of custom scheme (default: false)
    /// - Returns: Deep link URL string
    /// - Throws: InviteGenerationError or EncodingError
    func generateDeepLink(userId: String, deviceId: String, server: String? = nil, useHTTPS: Bool = false) throws -> String {
        let normalizedServer = normalizeServer(server ?? defaultServer)
        let payload = try generateQRPayload(userId: userId, deviceId: deviceId, server: normalizedServer)
        
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
        Log.debug("🔐 Using signing secret key for invite signing (\(keyBytes.count) bytes)", category: "InviteGenerator")
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
