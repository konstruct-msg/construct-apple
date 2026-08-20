//
//  InviteVerifier.swift
//  Construct Messenger
//
//  Created by Copilot on 29.01.2026.
//  2026-07-23: verify() is the redeem trust root; deviceId pin against identity key (F3 / thread 5.1).
//

import Foundation

/// Result of a successful local invite verification.
struct VerifiedInvite: Equatable {
    let invite: InviteObject
    /// Inviter identity public key from the key bundle (TOFU pin material).
    let identityPublic: Data
    let verifyingKey: Data
}

/// Verifier for cryptographically secure one-time invite links
///
/// Usage:
/// ```swift
/// let verifier = InviteVerifier()
/// let invite = try verifier.decode(encodedString)
/// let verified = try await verifier.verify(invite)
/// ```
class InviteVerifier {

    // MARK: - JTI deduplication
    private var usedJtis: Set<String> = []
    private let jtiLock = NSLock()

    // MARK: - Decoding

    /// Decode invite from a text transport payload (base64url / base64 of compact binary, or legacy JSON).
    func decode(_ encoded: String) throws -> InviteObject {
        let invite: InviteObject
        do {
            invite = try InviteObject.fromBase64(encoded)
        } catch {
            Log.error("Failed to decode invite payload: \(error)", category: "InviteVerifier")
            throw InviteVerificationError.invalidEncoding
        }

        try invite.validate()

        Log.debug(
            "Decoded invite: jti=\(invite.jti.prefix(8))..., from=\(invite.uuid.prefix(8))...",
            category: "InviteVerifier"
        )
        return invite
    }

    /// Decode invite from raw QR byte-mode payload (compact binary, magic `CIv1`).
    func decodeBinary(_ data: Data) throws -> InviteObject {
        let invite: InviteObject
        do {
            invite = try InviteObject.decodePayload(data)
        } catch {
            Log.error("Failed to decode invite binary: \(error)", category: "InviteVerifier")
            throw InviteVerificationError.invalidEncoding
        }
        try invite.validate()
        Log.debug(
            "Decoded binary invite: jti=\(invite.jti.prefix(8))..., from=\(invite.uuid.prefix(8))...",
            category: "InviteVerifier"
        )
        return invite
    }

    /// Decode from deep link URL
    ///
    /// Supported formats:
    /// - `konstruct://add?invite=<base64url>`
    /// - `https://konstruct.cc/add?invite=<base64url>`
    func decodeFromURL(_ url: URL) throws -> InviteObject {
        guard let encoded = extractInviteString(from: url), !encoded.isEmpty else {
            Log.error("Missing invite parameter in URL: \(url.absoluteString)", category: "InviteVerifier")
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

    /// Verify invite signature, expiry, and deviceId↔identity pin **locally**.
    ///
    /// This is the redeem-path trust root. Server `AcceptInvite` must not be treated as
    /// signature authority — only as jti burn / rate-limit.
    ///
    /// Checks:
    /// 1. Structure + TTL
    /// 2. Local JTI de-dupe (best-effort, in-memory)
    /// 3. Fetch inviter verifying key + identity key
    /// 4. `deviceId == deriveDeviceId(identityPublic)` when deviceId present (v2+)
    /// 5. Ed25519 signature over canonical string
    @discardableResult
    func verify(
        _ invite: InviteObject,
        ttl: TimeInterval = InviteConfig.ttlSeconds
    ) async throws -> VerifiedInvite {
        try invite.validate()

        if invite.server != ServerConfig.inviteHost {
            Log.info(
                "Invite server differs from configured host: invite=\(invite.server), expected=\(ServerConfig.inviteHost)",
                category: "InviteVerifier"
            )
        }

        guard !invite.isExpired(ttl: ttl) else {
            Log.info("Invite expired: jti=\(invite.jti.prefix(8))...", category: "InviteVerifier")
            throw InviteVerificationError.expired
        }

        guard !jtiLock.withLock({ usedJtis.contains(invite.jti) }) else {
            Log.info("Invite JTI already used: \(invite.jti.prefix(8))...", category: "InviteVerifier")
            throw InviteVerificationError.alreadyUsed
        }

        let publicKeyBundle = try await fetchPublicKey(
            userId: invite.uuid,
            deviceId: invite.deviceId.isEmpty ? nil : invite.deviceId,
            server: invite.server
        )

        let verifyingKeyData = publicKeyBundle.verifyingKey
        guard !verifyingKeyData.isEmpty else {
            Log.error("Empty verifyingKey in bundle", category: "InviteVerifier")
            throw InviteVerificationError.invalidVerifyingKey
        }

        let identityPublic = publicKeyBundle.identityPublic
        guard !identityPublic.isEmpty else {
            Log.error("Empty identityPublic in bundle", category: "InviteVerifier")
            throw InviteVerificationError.invalidVerifyingKey
        }

        // TOFU pin: signed deviceId must match SHA256(identity_public)[0..16].
        // Server key substitution for a different device/identity fails this check.
        if !invite.deviceId.isEmpty {
            let expectedDeviceId = deriveDeviceId(identityPublicKey: [UInt8](identityPublic))
            guard invite.deviceId.lowercased() == expectedDeviceId.lowercased() else {
                Log.info(
                    "Invite deviceId mismatch: invite=\(invite.deviceId.prefix(8))… expected=\(expectedDeviceId.prefix(8))…",
                    category: "InviteVerifier"
                )
                throw InviteVerificationError.deviceIdMismatch
            }
        }

        guard let signatureData = Data(base64Encoded: invite.sig) else {
            throw InviteVerificationError.invalidSignature
        }

        let dataToVerify = try invite.canonicalString()
        var isValid = try verifyInviteSignature(
            data: dataToVerify,
            signature: [UInt8](signatureData),
            verifyingKey: [UInt8](verifyingKeyData)
        )

        if !isValid, invite.server.contains("http") {
            // Compatibility: some older invites stored server with scheme.
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
                un: invite.un,
                // Carried, not dropped: on v5 the canonical string ends with `ttl`, so a
                // rebuild that omitted it would hash a different string and report the
                // signature invalid — with the server as the last place anyone would look.
                ttl: invite.ttl
            )
            isValid = try verifyInviteSignature(
                data: try normalizedInvite.canonicalString(),
                signature: [UInt8](signatureData),
                verifyingKey: [UInt8](verifyingKeyData)
            )
            if isValid {
                Log.info(
                    "Invite signature valid after server normalization: jti=\(invite.jti.prefix(8))..., server=\(normalizedServer)",
                    category: "InviteVerifier"
                )
            }
        }

        guard isValid else {
            Log.info("Invalid invite signature: jti=\(invite.jti.prefix(8))...", category: "InviteVerifier")
            throw InviteVerificationError.invalidSignature
        }

        _ = jtiLock.withLock { self.usedJtis.insert(invite.jti) }
        Log.info("Invite signature valid: jti=\(invite.jti.prefix(8))...", category: "InviteVerifier")

        return VerifiedInvite(
            invite: invite,
            identityPublic: identityPublic,
            verifyingKey: verifyingKeyData
        )
    }

    /// Check if invite has expired (local check only)
    func checkExpiry(_ invite: InviteObject, ttl: TimeInterval = InviteConfig.ttlSeconds) -> Bool {
        invite.isExpired(ttl: ttl)
    }

    // MARK: - Helper Methods

    private func fetchPublicKey(
        userId: String,
        deviceId: String?,
        server: String
    ) async throws -> PublicKeyBundleData {
        do {
            // Prefer the invite's device so verifying key matches the signer.
            // Verifying key only — invite verification must never burn the inviter's OTPKs
            // (an invite link opened repeatedly would otherwise drain their pool).
            let bundle = try await KeyServiceClient.shared.getPreKeyBundle(
                userId: userId,
                deviceId: deviceId,
                consumeOneTimePrekey: false
            )
            Log.debug(
                "Fetched key bundle for \(userId.prefix(8))… device=\(deviceId?.prefix(8) ?? "default")",
                category: "InviteVerifier"
            )
            return bundle
        } catch {
            Log.error("Failed to fetch key bundle for \(userId): \(error)", category: "InviteVerifier")
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
    case deviceIdMismatch
    case expired
    case publicKeyFetchFailed(Error)
    case alreadyUsed

    var errorDescription: String? {
        switch self {
        case .invalidEncoding:
            return "Invalid invite encoding (expected compact binary / base64url)"
        case .invalidSignature:
            return "Invalid or tampered signature"
        case .invalidVerifyingKey:
            return "Invalid verifying key format"
        case .deviceIdMismatch:
            return "Invite device does not match identity key"
        case .expired:
            return "Invite has expired"
        case .publicKeyFetchFailed(let error):
            return "Failed to fetch public key: \(error.localizedDescription)"
        case .alreadyUsed:
            return "Invite already used (JTI conflict)"
        }
    }
}
