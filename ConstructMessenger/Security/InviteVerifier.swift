//
//  InviteVerifier.swift
//  Construct Messenger
//
//  Created by Copilot on 29.01.2026.
//

import Foundation

/// Verifier for cryptographically secure one-time invite links
///
/// Usage:
/// ```swift
/// let verifier = InviteVerifier()
/// let invite = try verifier.decode(encodedString)
/// let isValid = try await verifier.verify(invite)
/// ```
class InviteVerifier {
    
    // MARK: - JTI deduplication
    private var usedJtis: Set<String> = []
    private let jtiLock = NSLock()
    
    // MARK: - Decoding
    
    /// Decode invite from Base64-encoded MessagePack
    ///
    /// Expected format: Base64(MessagePack(InviteObject))
    /// This is the production format for QR codes and links.
    ///
    /// - Parameter encoded: Base64-encoded MessagePack string
    /// - Returns: Decoded InviteObject
    /// - Throws: InviteVerificationError
    func decode(_ encoded: String) throws -> InviteObject {
        // Decode from Base64-encoded MessagePack
        let invite = try InviteObject.fromBase64(encoded)
        
        // Validate structure
        try invite.validate()
        
        Log.debug("📥 Decoded invite: jti=\(invite.jti.prefix(8))..., from=\(invite.uuid.prefix(8))...", category: "InviteVerifier")
        
        return invite
    }
    
    /// Decode from deep link URL
    ///
    /// Supported formats:
    /// - `konstruct://add?invite=<base64>`
    /// - `https://konstruct.cc/add?invite=<base64>`
    ///
    /// - Parameter url: Deep link URL
    /// - Returns: Decoded InviteObject
    /// - Throws: InviteVerificationError
    func decodeFromURL(_ url: URL) throws -> InviteObject {
        guard let encoded = extractInviteString(from: url), !encoded.isEmpty else {
            Log.error("❌ Missing invite parameter in URL: \(url.absoluteString)", category: "InviteVerifier")
            throw InviteVerificationError.invalidEncoding
        }
        return try decode(encoded)
    }

    private func extractInviteString(from url: URL) -> String? {
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: true) {
            if let inviteParam = components.queryItems?.first(where: { $0.name == "invite" }),
               let value = inviteParam.value {
                return value
            }
        }

        // Fallback: /add/<invite>
        let pathComponents = url.path.split(separator: "/").map(String.init)
        if let addIndex = pathComponents.firstIndex(of: "add"),
           pathComponents.count > addIndex + 1 {
            return pathComponents[addIndex + 1]
        }

        // Fallback: fragment contains invite
        if let fragment = url.fragment, !fragment.isEmpty {
            if fragment.hasPrefix("invite=") {
                return String(fragment.dropFirst("invite=".count))
            }
            return fragment
        }

        return nil
    }
    
    // MARK: - Verification
    
    /// Verify invite signature and expiry
    ///
    /// Checks:
    /// 1. Signature is valid (signed by claimed user)
    /// 2. Invite is not expired (TTL check)
    /// 3. (Server-side) JTI not already used
    ///
    /// - Parameters:
    ///   - invite: InviteObject to verify
    ///   - ttl: Time-to-live in seconds (default: 300 = 5 minutes)
    /// - Returns: true if valid
    /// - Throws: InviteVerificationError
    func verify(_ invite: InviteObject, ttl: TimeInterval = InviteConfig.ttlSeconds) async throws -> Bool {
        // Step 1: Check structure validity
        try invite.validate()

        if invite.server != ServerConfig.inviteHost {
            Log.info("ℹ️ Invite server differs from configured host: invite=\(invite.server), expected=\(ServerConfig.inviteHost)", category: "InviteVerifier")
        }
        
        // Step 2: Check expiry
        guard !invite.isExpired(ttl: ttl) else {
            Log.info("⚠️ Invite expired: jti=\(invite.jti.prefix(8))...", category: "InviteVerifier")
            throw InviteVerificationError.expired
        }
        
        // Step 2a: Check JTI deduplication
        guard !jtiLock.withLock({ usedJtis.contains(invite.jti) }) else {
            Log.info("⚠️ Invite JTI already used: \(invite.jti.prefix(8))...", category: "InviteVerifier")
            throw InviteVerificationError.alreadyUsed
        }
        
        // Step 3: Fetch sender's public key bundle
        let publicKeyBundle = try await fetchPublicKey(userId: invite.uuid, server: invite.server)
        
        // Step 4: Validate verifying key
        let verifyingKeyData = publicKeyBundle.verifyingKey
        guard !verifyingKeyData.isEmpty else {
            Log.error("❌ Empty verifyingKey in bundle", category: "InviteVerifier")
            throw InviteVerificationError.invalidVerifyingKey
        }
        
        Log.debug("🔐 VERIFY: Server verifying key (first 16 bytes): \(verifyingKeyData.prefix(16).map { String(format: "%02x", $0) }.joined())...", category: "InviteVerifier")
        Log.debug("🔐 Verifying key from server (first 16 bytes): \(verifyingKeyData.prefix(16).base64EncodedString())", category: "InviteVerifier")
        
        // Step 5: Extract signature
        guard let signatureData = Data(base64Encoded: invite.sig) else {
            throw InviteVerificationError.invalidSignature
        }
        
        // Step 6: Get canonical string (same as used for signing)
        let dataToVerify = invite.canonicalString()
        
        Log.debug("🔐 VERIFY: Data to verify: \(dataToVerify)", category: "InviteVerifier")
        Log.debug("🔐 VERIFY: Signature: \(invite.sig)", category: "InviteVerifier")
        
        Log.debug("🔐 Data to verify: \(dataToVerify)", category: "InviteVerifier")
        Log.debug("🔐 Signature base64: \(invite.sig)", category: "InviteVerifier")
        
        // Step 7: Verify signature using Rust core
        Log.debug("🔐 VERIFY: Calling Rust verifyInviteSignature", category: "InviteVerifier")
        Log.debug("   Data bytes: \(dataToVerify.utf8.count)", category: "InviteVerifier")
        Log.debug("   Signature bytes: \(signatureData.count)", category: "InviteVerifier")
        Log.debug("   Verifying key bytes: \(verifyingKeyData.count)", category: "InviteVerifier")
        
        let isValid = try verifyInviteSignature(
            data: dataToVerify,
            signature: [UInt8](signatureData),
            verifyingKey: [UInt8](verifyingKeyData)
        )
        
        Log.debug("🔐 VERIFY: Rust returned: \(isValid)", category: "InviteVerifier")
        
        if isValid {
            Log.info("✅ Invite signature valid: jti=\(invite.jti.prefix(8))...", category: "InviteVerifier")
        } else {
            // Compatibility: some older invites stored server with scheme.
            if invite.server.contains("http") {
                let normalizedServer = normalizeServer(invite.server)
                let normalizedInvite = InviteObject(
                    v: invite.v,
                    jti: invite.jti,
                    uuid: invite.uuid,
                    deviceId: invite.deviceId,
                    server: normalizedServer,
                    ephKey: invite.ephKey,
                    ts: invite.ts,
                    sig: invite.sig,
                    un: invite.un
                )
                
                let normalizedData = normalizedInvite.canonicalString()
                let normalizedValid = try verifyInviteSignature(
                    data: normalizedData,
                    signature: [UInt8](signatureData),
                    verifyingKey: [UInt8](verifyingKeyData)
                )
                
                if normalizedValid {
                    Log.info("✅ Invite signature valid after server normalization: jti=\(invite.jti.prefix(8))..., server=\(normalizedServer)", category: "InviteVerifier")
                    _ = jtiLock.withLock { self.usedJtis.insert(invite.jti) }
                    return true
                }
            }
            
            Log.info("❌ Invalid invite signature: jti=\(invite.jti.prefix(8))...", category: "InviteVerifier")
            throw InviteVerificationError.invalidSignature
        }
        
        if isValid {
            _ = jtiLock.withLock { self.usedJtis.insert(invite.jti) }
        }
        return isValid
    }
    
    /// Check if invite has expired (local check only)
    /// - Parameters:
    ///   - invite: InviteObject
    ///   - ttl: Time-to-live in seconds
    /// - Returns: true if expired
    func checkExpiry(_ invite: InviteObject, ttl: TimeInterval = InviteConfig.ttlSeconds) -> Bool {
        return invite.isExpired(ttl: ttl)
    }
    
    // MARK: - Helper Methods
    
    /// Fetch public key bundle from server
    /// - Parameters:
    ///   - userId: User UUID
    /// Fetches the user's verifying (Ed25519) public key from the server.
    ///   - userId: The invite owner's UUID
    ///   - server: Server FQDN (currently unused — client always talks to configured server)
    /// - Returns: PublicKeyBundleData with verifyingKey populated
    /// - Throws: InviteVerificationError
    private func fetchPublicKey(userId: String, server: String) async throws -> PublicKeyBundleData {
        do {
            let bundle = try await KeyServiceClient.shared.getPreKeyBundle(userId: userId)
            Log.debug("🔑 Fetched key bundle for \(userId.prefix(8))", category: "InviteVerifier")
            return bundle
        } catch {
            Log.error("❌ Failed to fetch key bundle for \(userId): \(error)", category: "InviteVerifier")
            throw InviteVerificationError.publicKeyFetchFailed(error)
        }
    }

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
}

// MARK: - Errors

enum InviteVerificationError: LocalizedError {
    case invalidEncoding
    case invalidSignature
    case invalidVerifyingKey
    case expired
    case publicKeyFetchFailed(Error)
    case alreadyUsed
    
    var errorDescription: String? {
        switch self {
        case .invalidEncoding:
            return "Invalid Base64 or MessagePack encoding"
        case .invalidSignature:
            return "Invalid or tampered signature"
        case .invalidVerifyingKey:
            return "Invalid verifying key format"
        case .expired:
            return "Invite has expired"
        case .publicKeyFetchFailed(let error):
            return "Failed to fetch public key: \(error.localizedDescription)"
        case .alreadyUsed:
            return "Invite already used (JTI conflict)"
        }
    }
}
