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

    /// This account's address, read at mint time. Injected so a test can mint without a Keychain.
    private let accountAddress: () -> Data?

    init(
        defaultServer: String = "konstruct.cc",
        accountAddress: @escaping () -> Data? = AccountAddress.own
    ) {
        self.defaultServer = defaultServer
        self.accountAddress = accountAddress
    }
    
    // MARK: - Generation
    
    /// Generate a new invite object (v5).
    ///
    /// Process:
    /// 1. Create JTI (UUIDv4)
    /// 2. Build the invite, naming this account's address
    /// 3. Sign with this device's Ed25519 key
    ///
    /// Refuses without an address (`noAccountAddress`): an invite that named none would leave the
    /// redeemer writing to a server-assigned id, and one that named a wrong one would lose every
    /// message sent to it. The UI gates on `RecoveryGate` before it gets here.
    ///
    /// - Parameters:
    ///   - userId: Sender's user UUID (for chat creation)
    ///   - deviceId: Sender's device ID (for fetching keys)
    ///   - username: Optional plaintext @alias in the signed payload. **Default nil**
    ///     (metadata minimization). Never pass for HTTPS deep links.
    ///   - serverFQDN: Server FQDN (optional, uses default if nil)
    ///   - ttlSeconds: how long this invite should stay redeemable. Pass the artifact's own
    ///     life — a QR is scanned in seconds, a link waits in an inbox for hours.
    /// - Returns: Signed InviteObject
    /// - Throws: InviteGenerationError
    func generate(
        userId: String,
        deviceId: String,
        username: String? = nil,
        serverFQDN: String? = nil,
        ttlSeconds: UInt32
    ) throws -> InviteObject {
        guard UUID(uuidString: userId) != nil else {
            throw InviteGenerationError.invalidUserId
        }
        guard deviceId.count == InviteConfig.deviceIdLength,
              deviceId.range(of: InviteConfig.deviceIdRegex, options: .regularExpression) != nil else {
            throw InviteGenerationError.invalidDeviceId
        }

        guard let addr = accountAddress() else {
            throw InviteGenerationError.noAccountAddress
        }

        let server = normalizeServer(serverFQDN ?? defaultServer)
        let jti = UUID().uuidString.lowercased()
        let timestamp = Int(Date().timeIntervalSince1970)
        let version = InviteConfig.version

        let normalizedUsername = username
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }

        let unsignedInvite = InviteObject(
            v: version,
            jti: jti,
            uuid: userId.lowercased(),
            deviceId: deviceId,
            server: server,
            ts: timestamp,
            sig: "",
            un: normalizedUsername,
            ttl: ttlSeconds,
            addr: addr
        )

        let dataToSign = try unsignedInvite.canonicalString()
        Log.debug("Canonical string for signing: \(dataToSign)", category: "InviteGenerator")

        let (signature, verifyingKey) = try signWithDeviceKey(Data(dataToSign.utf8))

        // Against the verifying key we publish, which is what a recipient checks it with.
        let isSelfValid = try verifyInviteSignature(
            data: dataToSign,
            signature: signature,
            verifyingKey: verifyingKey
        )
        if !isSelfValid {
            Log.error("Invite self-verify failed (signing key mismatch)", category: "InviteGenerator")
            throw InviteGenerationError.signingFailed
        }

        let signedInvite = unsignedInvite.signed(signature.base64EncodedString())

        try signedInvite.validate()

        let liveFor = Int(signedInvite.effectiveTTLSeconds / 60)
        Log.info(
            "Generated invite v\(version): jti=\(jti.prefix(8))..., expires in \(liveFor) min",
            category: "InviteGenerator"
        )
        return signedInvite
    }
    
    // MARK: - QR Code & Link Generation

    /// A minted invite together with the artifact carrying it.
    ///
    /// The `jti` leaves the generator alongside the artifact on purpose. These methods used
    /// to return the URL or the payload alone, discarding the identifier of the capability
    /// they had just signed — and a `jti` the issuing device does not keep is a capability
    /// nobody can revoke, because the server holds no record of an invite until someone
    /// redeems it. `InviteJournal` is the intended keeper.
    struct MintedInvite<Artifact> {
        let jti: String
        let issuedAt: Date
        /// The stated life. Travels with the jti for the same reason the jti travels at all:
        /// the journal has to know when what it recorded stops working, and asking the global
        /// constant would be wrong the moment two artifacts differ.
        let ttl: UInt32
        let artifact: Artifact
    }

    /// Generate compact binary payload for QR **byte mode** (no base64).
    ///
    /// Smaller than legacy base64(JSON) deep links; pair with `QRCodeGenerator.generate(from:)`.
    /// A QR gets `InviteConfig.qrTTLSeconds`, not the link's twelve hours: it is scanned
    /// within seconds of appearing and never waits in an inbox.
    func generateQRBinary(
        userId: String,
        deviceId: String,
        username: String? = nil,
        server: String? = nil,
        ttlSeconds: UInt32 = InviteConfig.qrTTLSeconds
    ) throws -> MintedInvite<Data> {
        let invite = try generate(
            userId: userId,
            deviceId: deviceId,
            username: username,
            serverFQDN: normalizeServer(server ?? defaultServer),
            ttlSeconds: ttlSeconds
        )
        return MintedInvite(
            jti: invite.jti,
            issuedAt: Date(timeIntervalSince1970: TimeInterval(invite.ts)),
            ttl: invite.ttl,
            artifact: try invite.encodeBinary()
        )
    }

    /// Generate text-safe payload for clipboard / base64-like QR fallbacks.
    /// base64url over compact binary (not JSON).
    func generateQRPayload(
        userId: String,
        deviceId: String,
        username: String? = nil,
        server: String? = nil,
        ttlSeconds: UInt32 = InviteConfig.qrTTLSeconds
    ) throws -> MintedInvite<String> {
        let binary = try generateQRBinary(
            userId: userId,
            deviceId: deviceId,
            username: username,
            server: server,
            ttlSeconds: ttlSeconds
        )
        return MintedInvite(
            jti: binary.jti,
            issuedAt: binary.issuedAt,
            ttl: binary.ttl,
            artifact: InviteBinaryCodec.base64URLEncode(binary.artifact)
        )
    }

    /// Generate deep link URL for sharing
    ///
    /// Format: `konstruct://add?invite=<base64url>`
    /// Also supports: `https://konstruct.cc/add?invite=<base64url>`
    ///
    /// The invite query value is base64url(compact binary) — URLs are a text boundary.
    ///
    /// A link keeps the full `InviteConfig.ttlSeconds`. It is the artifact that travels
    /// through another messenger and waits in an inbox, which is the reason that number is
    /// twelve hours in the first place.
    func generateDeepLink(
        userId: String,
        deviceId: String,
        username: String? = nil,
        server: String? = nil,
        useHTTPS: Bool = false,
        ttlSeconds: UInt32 = UInt32(InviteConfig.ttlSeconds)
    ) throws -> MintedInvite<String> {
        let normalizedServer = normalizeServer(server ?? defaultServer)
        let payload = try generateQRPayload(
            userId: userId,
            deviceId: deviceId,
            username: username,
            server: normalizedServer,
            ttlSeconds: ttlSeconds
        )

        let url = useHTTPS
            ? "https://\(normalizedServer)/add?invite=\(payload.artifact)"
            : "konstruct://add?invite=\(payload.artifact)"
        return MintedInvite(jti: payload.jti, issuedAt: payload.issuedAt, ttl: payload.ttl, artifact: url)
    }
    
    // MARK: - Helper Methods
    
    /// The core's Ed25519 signature over `data` and the verifying key it checks against. The
    /// signing key stays in the core.
    private func signWithDeviceKey(_ data: Data) throws -> (signature: Data, verifyingKey: Data) {
        let crypto = CryptoManager.shared
        crypto.coreLock.lock()
        defer { crypto.coreLock.unlock() }
        guard let core = crypto.orchestratorCore else {
            throw InviteGenerationError.missingIdentityKey
        }
        return (try core.signWithDeviceKey(message: data), try core.getRegistrationBundleFields().verifyingKey)
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
    case signingFailed
    case noAccountAddress

    var errorDescription: String? {
        switch self {
        case .invalidUserId:
            return "Invalid user ID (must be UUIDv4)"
        case .invalidDeviceId:
            return "Invalid device ID (must be 32-char hex)"
        case .missingIdentityKey:
            return "Identity key not available. User may not be logged in."
        case .signingFailed:
            return "Failed to sign invite data"
        case .noAccountAddress:
            return "This device does not know the account's address — confirm the recovery phrase"
        }
    }
}
