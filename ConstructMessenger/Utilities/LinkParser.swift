//
//  LinkParser.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 07.01.2026.
//  Updated for Dynamic Invites on 30.01.2026.
//

import Foundation

enum ContactLinkError: Error, LocalizedError {
    case invalidURL
    case invalidPrefix
    case invalidPath
    case missingUserId
    case missingUsername
    case inviteExpired
    case inviteInvalid(String)
    case verificationFailed(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return NSLocalizedString("The provided URL is invalid.", comment: "")
        case .invalidPrefix: return NSLocalizedString("The URL does not have the expected prefix for a contact link.", comment: "")
        case .invalidPath: return NSLocalizedString("The URL path is not in the correct format.", comment: "")
        case .missingUserId: return NSLocalizedString("The contact link is missing the user ID.", comment: "")
        case .missingUsername: return NSLocalizedString("The contact link is missing the username.", comment: "")
        case .inviteExpired: return NSLocalizedString("This invite has expired. Ask for a new one.", comment: "")
        case .inviteInvalid(let reason): return NSLocalizedString("Invalid invite: \(reason)", comment: "")
        case .verificationFailed(let error): return NSLocalizedString("Verification failed: \(error.localizedDescription)", comment: "")
        }
    }
}

struct ContactInfo: Equatable {
    let userId: String
    let deviceId: String?      // Device ID for fetching keys
    let username: String
    let ephemeralKey: String?  // For Dynamic Invites
    let isDynamic: Bool        // True if from Dynamic Invite
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
        
        // Try Dynamic Invite format first
        if isDynamicInviteURL(url) {
            do {
                return try await parseDynamicInvite(url)
            } catch {
                Log.info("Dynamic invite parse failed, trying legacy parser: \(error.localizedDescription)", category: "LinkParser")
                if isLegacyContactURL(url) {
                    return try parseLegacyContactLink(url)
                }
                throw error
            }
        }
        
        // Fallback to legacy format
        if isLegacyContactURL(url) {
            return try parseLegacyContactLink(url)
        }

        Log.error("Unsupported contact link prefix: \(urlString)", category: "LinkParser")
        throw ContactLinkError.invalidPrefix
    }
    
    // MARK: - Dynamic Invite Parsing
    
    private static func parseDynamicInvite(_ url: URL) async throws -> ContactInfo {
        Log.info("Parsing Dynamic Invite URL", category: "LinkParser")
        
        // Decode invite from URL
        let invite: InviteObject
        do {
            invite = try verifier.decodeFromURL(url)
        } catch {
            Log.error("Failed to decode invite: \(error)", category: "LinkParser")
            throw ContactLinkError.inviteInvalid("Malformed invite data")
        }
        
        // Quick local TTL check (no server round-trip)
        if invite.isExpired(ttl: InviteConfig.ttlSeconds) {
            Log.info("Invite expired: jti=\(invite.jti.prefix(8))...", category: "LinkParser")
            throw ContactLinkError.inviteExpired
        }
        
        // Call AcceptInvite — server verifies signature and burns JTI (one-time use)
        var inviteToken = Shared_Proto_Services_V1_InviteToken()
        inviteToken.v = Int32(invite.v)
        inviteToken.jti = invite.jti
        inviteToken.uuid = invite.uuid
        inviteToken.server = invite.server
        inviteToken.ts = Int64(invite.ts)
        inviteToken.ephPub = invite.ephKey
        inviteToken.sig = invite.sig
        if !invite.deviceId.isEmpty {
            inviteToken.deviceID = invite.deviceId
        }
        if let un = invite.un, !un.isEmpty {
            inviteToken.un = un
        }
        
        var acceptRequest = Shared_Proto_Services_V1_AcceptInviteRequest()
        acceptRequest.invite = inviteToken
        
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
            throw ContactLinkError.verificationFailed(error)
        }
        
        let userId = response.userID.isEmpty ? invite.uuid : response.userID
        let deviceId = response.hasDeviceID ? response.deviceID : invite.deviceId
        
        Log.info("Invite accepted: userId=\(userId.prefix(8))..., deviceId=\(deviceId)", category: "LinkParser")
        
        // Use the sender's username from the invite payload if present (V3+, cryptographically signed).
        // Falls back to userId as a placeholder that will be overwritten once the session is live.
        let trimmedUsername = invite.un?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedUsername = trimmedUsername.isEmpty ? userId : trimmedUsername
        
        return ContactInfo(
            userId: userId,
            deviceId: deviceId,
            username: resolvedUsername,
            ephemeralKey: invite.ephKey,
            isDynamic: true
        )
    }
    
    // MARK: - Legacy Format Parsing

    private static func parseLegacyContactLink(_ url: URL) throws -> ContactInfo {
        Log.info("Parsing legacy contact link", category: "LinkParser")
        
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ContactLinkError.invalidURL
        }

        // Extract userId from path: /c/{userId}
        let path = components.path
        let pathComponents = path.split(separator: "/").map(String.init)
        
        guard pathComponents.count == 2, pathComponents[0] == "c", let userId = pathComponents.get(at: 1) else {
            throw ContactLinkError.invalidPath
        }

        // Extract username from query items
        var username: String?
        if let queryItems = components.queryItems {
            for item in queryItems {
                if item.name == "username", let value = item.value {
                    username = value.removingPercentEncoding ?? value
                    break
                }
            }
        }
        
        guard let finalUsername = username, !finalUsername.isEmpty else {
            throw ContactLinkError.missingUsername
        }

        return ContactInfo(
            userId: userId,
            deviceId: nil,  // Legacy format doesn't have deviceId
            username: finalUsername,
            ephemeralKey: nil,
            isDynamic: false
        )
    }

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
