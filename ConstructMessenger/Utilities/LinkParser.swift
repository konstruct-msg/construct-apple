//
//  LinkParser.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 07.01.2026.
//  Updated for Dynamic Invites on 30.01.2026.
//  2026-07-23: client-side verify is trust root; legacy /c/ removed (F3/F4).
//

import Foundation

enum ContactLinkError: Error, LocalizedError {
    case invalidURL
    case invalidPrefix
    case inviteExpired
    case inviteInvalid(String)
    case inviteAlreadyUsed
    case verificationFailed(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return NSLocalizedString("invite_error_invalid_url", comment: "")
        case .invalidPrefix:
            return NSLocalizedString("invite_error_unsupported_link", comment: "")
        case .inviteExpired:
            return NSLocalizedString("invite_error_expired", comment: "")
        case .inviteInvalid(let reason):
            return String(
                format: NSLocalizedString("invite_error_invalid_fmt", comment: ""),
                reason
            )
        case .inviteAlreadyUsed:
            return NSLocalizedString("invite_error_already_used", comment: "")
        case .verificationFailed(let error):
            return String(
                format: NSLocalizedString("invite_error_verification_failed_fmt", comment: ""),
                error.localizedDescription
            )
        }
    }
}

struct ContactInfo: Equatable {
    let userId: String
    let deviceId: String?      // Device ID for fetching keys
    let username: String
    let ephemeralKey: String?  // Present only on legacy v1–v3 invites (unused)
    let isDynamic: Bool        // True if from signed Dynamic Invite
    /// Inviter identity public key from the verified key bundle (TOFU pin material).
    let identityPublicKey: Data?
}

struct LinkParser {
    private static var allowedHosts: Set<String> {
        [
            ServerConfig.inviteHost,
            "web.\(ServerConfig.inviteHost)"
        ]
    }

    private static let verifier = InviteVerifier()

    static func parseContactLink(_ url: URL) async throws -> ContactInfo {
        let urlString = url.absoluteString

        // Signed dynamic invite only — no legacy `/c/{uuid}?username=` downgrade path (F4).
        if isDynamicInviteURL(url) {
            return try await parseDynamicInvite(url)
        }

        // Clear rejection of unsigned legacy contact URLs (no silent accept).
        if isLegacyContactURL(url) {
            Log.info("Rejected legacy unsigned /c/ contact link", category: "LinkParser")
            throw ContactLinkError.inviteInvalid(
                NSLocalizedString("invite_error_legacy_unsupported", comment: "")
            )
        }

        Log.error("Unsupported contact link prefix: \(urlString)", category: "LinkParser")
        throw ContactLinkError.invalidPrefix
    }

    // MARK: - Dynamic Invite Parsing

    private static func parseDynamicInvite(_ url: URL) async throws -> ContactInfo {
        Log.info("Parsing Dynamic Invite URL", category: "LinkParser")

        // 1. Decode invite from URL
        let invite: InviteObject
        do {
            invite = try verifier.decodeFromURL(url)
        } catch {
            Log.error("Failed to decode invite: \(error)", category: "LinkParser")
            throw ContactLinkError.inviteInvalid(
                NSLocalizedString("invite_error_malformed", comment: "")
            )
        }

        // 2. Client-side signature verify is the trust root (F3).
        //    Server AcceptInvite remains for jti burn + rate-limit only.
        let verified: VerifiedInvite
        do {
            verified = try await verifier.verify(invite)
        } catch let error as InviteVerificationError {
            throw mapVerificationError(error)
        } catch {
            throw ContactLinkError.verificationFailed(error)
        }

        // 3. AcceptInvite — one-time jti burn + transitional contact edge recording
        var acceptRequest = Shared_Proto_Services_V1_AcceptInviteRequest()
        acceptRequest.invite = protoToken(from: invite)

        // Retry AcceptInvite with backoff — "Stream unexpectedly closed" happens when
        // VEIL is reconnecting. A few attempts let the transport stabilize.
        let response: Shared_Proto_Services_V1_AcceptInviteResponse
        do {
            response = try await withRetry(
                maxAttempts: 3,
                backoff: 1.5,
                retryIf: { error in
                    let desc = error.localizedDescription.lowercased()
                    return desc.contains("stream") || desc.contains("unavailable") || desc.contains("closed")
                },
                label: "AcceptInvite"
            ) {
                try await InviteServiceClient.shared.acceptInvite(invite: acceptRequest)
            }
        } catch {
            // The server's verdict, not the bridged NSError description. `AcceptInvite` is
            // where a revoked link is refused, and until this classification existed that
            // refusal reached the user as "(GRPCCore.RPCError error 1.)" — a digit that is
            // the same for every error Swift ever bridges.
            throw mapAcceptError(InviteAcceptClassification.outcome(from: error))
        }

        let userId = response.userID.isEmpty ? invite.uuid : response.userID
        let deviceId = response.hasDeviceID ? response.deviceID : invite.deviceId

        Log.info(
            "Invite accepted (client-verified): userId=\(userId.prefix(8))..., deviceId=\(deviceId.prefix(8))…",
            category: "LinkParser"
        )

        // Use the sender's username from the invite payload if present (V3+, cryptographically signed).
        // Falls back to userId as a placeholder that will be overwritten once the session is live.
        let trimmedUsername = invite.un?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedUsername = trimmedUsername.isEmpty ? userId : trimmedUsername

        let eph: String? = invite.ephKey.isEmpty ? nil : invite.ephKey

        return ContactInfo(
            userId: userId,
            deviceId: deviceId,
            username: resolvedUsername,
            ephemeralKey: eph,
            isDynamic: true,
            identityPublicKey: verified.identityPublic
        )
    }

    /// The decoded invite, rebuilt as the wire message `AcceptInvite` carries.
    ///
    /// A named boundary rather than twelve assignments inside `parseDynamicInvite`, because
    /// the server rebuilds the canonical string from exactly these fields and re-checks the
    /// signature against it. A field omitted here does not read as missing data — it reads
    /// as a bad signature, on the server, for an invite that verified perfectly on this
    /// device a moment earlier. That was not hypothetical: `ttl` could be dropped from this
    /// mapping and the whole suite still passed, because nothing could reach the mapping.
    static func protoToken(from invite: InviteObject) -> Shared_Proto_Services_V1_InviteToken {
        var token = Shared_Proto_Services_V1_InviteToken()
        token.v = Int32(invite.v)
        token.jti = invite.jti
        token.uuid = invite.uuid
        token.server = invite.server
        token.ts = Int64(invite.ts)
        // v4+: empty; v1–v3: still sent for server dual-read of old invites
        token.ephPub = invite.ephKey
        token.sig = invite.sig
        if !invite.deviceId.isEmpty {
            token.deviceID = invite.deviceId
        }
        if let un = invite.un, !un.isEmpty {
            token.un = un
        }
        // v5 only, and mandatory there: the canonical string ends with it.
        if let ttl = invite.ttl {
            token.ttl = ttl
        }
        return token
    }

    /// The server's `AcceptInvite` verdict as the error the UI already knows how to say.
    ///
    /// `.alreadyUsed` reuses the same sentence as a locally-detected replay on purpose:
    /// from the redeemer's side a burned `jti` is a burned `jti`, and whether this device
    /// or the server noticed is not their business.
    static func mapAcceptError(_ outcome: InviteAcceptOutcome) -> ContactLinkError {
        switch outcome {
        case .alreadyUsed:
            return .inviteAlreadyUsed
        case .expired:
            return .inviteExpired
        case .badSignature:
            return .inviteInvalid(NSLocalizedString("invite_error_malformed", comment: ""))
        case .refused(let detail):
            return .inviteInvalid(detail)
        case .unreachable(let detail):
            // Never `.inviteInvalid` — nothing was learned about the invite, and telling
            // someone to ask for a new link when the old one is fine wastes both sides.
            return .verificationFailed(InviteTransportFailure(detail: detail))
        }
    }

    /// Carries a server/transport detail through `ContactLinkError.verificationFailed`,
    /// whose message is built from `localizedDescription`.
    struct InviteTransportFailure: LocalizedError {
        let detail: String
        var errorDescription: String? { detail }
    }

    private static func mapVerificationError(_ error: InviteVerificationError) -> ContactLinkError {
        switch error {
        case .expired:
            return .inviteExpired
        case .alreadyUsed:
            return .inviteAlreadyUsed
        case .invalidSignature, .deviceIdMismatch, .invalidVerifyingKey, .invalidEncoding:
            return .inviteInvalid(error.localizedDescription)
        case .publicKeyFetchFailed(let underlying):
            return .verificationFailed(underlying)
        }
    }

    // MARK: - URL shape

    private static func isDynamicInviteURL(_ url: URL) -> Bool {
        if let scheme = url.scheme?.lowercased(), scheme == "konstruct" {
            if url.host?.lowercased() == "add" {
                return true
            }
            return url.path.lowercased().hasPrefix("/add")
        }

        guard let host = url.host?.lowercased() else { return false }
        return allowedHosts.contains(host) && url.path.lowercased().hasPrefix("/add")
    }

    private static func isLegacyContactURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return allowedHosts.contains(host) && url.path.lowercased().hasPrefix("/c/")
    }
}
