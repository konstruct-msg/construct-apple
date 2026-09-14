//
//  DeviceLinkOutcome.swift
//  Construct Messenger
//
//  Unified completion payload for all device-link flows.
//

import Foundation

/// Result of a completed device-link handshake (Flow A or Flow B).
struct DeviceLinkOutcome: Sendable, Equatable {
    enum Role: Sendable, Equatable {
        /// This device received JWTs (Flow A phone scan, Flow B desktop poll).
        case linkedNewDevice
        /// An already-authenticated device approved another's join request (Flow B phone).
        case approvedJoinRequest
    }

    let role: Role
    let userId: String
    let deviceId: String
    /// Flow B: pending device id encoded in the join-request QR (history-sync PIN input).
    let pendingDeviceId: String?
}

/// Post-link UI phase — drives history sync without intermediate alerts.
enum DeviceLinkPhase: Equatable {
    case idle
    case historySyncReceive(pendingDeviceId: String)
    case historySyncSend(pendingDeviceId: String)
}

/// Runtime gate for automatic post-link history transfer.
///
/// Nearby history transfer remains implemented, but account linking currently enters the app
/// without prompting for history so multi-device fan-out can be verified independently.
enum DeviceLinkHistorySyncPolicy {
    static let isPostLinkEnabled = false
}

/// Cursor policy for account-only links when history transfer is intentionally skipped.
enum DeviceLinkStreamCursorPolicy {
    static func checkpointCursor(accessToken: String) -> String? {
        guard let issuedAtSeconds = TokenUtils.extractIssuedAt(from: accessToken) else {
            return nil
        }
        return checkpointCursor(issuedAtSeconds: issuedAtSeconds)
    }

    static func checkpointCursor(issuedAtSeconds: Int64) -> String? {
        guard issuedAtSeconds > 0, issuedAtSeconds <= Int64.max / 1000 else {
            return nil
        }
        return "\(issuedAtSeconds * 1000)-0"
    }

    @MainActor
    static func applyAccountOnlyCheckpoint(accessToken: String) {
        guard let cursor = checkpointCursor(accessToken: accessToken) else {
            Log.error(
                "Account-only device link could not derive stream checkpoint from token iat; next stream may request full backlog",
                category: "DeviceLink"
            )
            return
        }

        StreamCursorStore.save(cursor)
        StreamCursorTracker.shared.reset()
        Log.info("Account-only device link checkpointed stream cursor=\(cursor)", category: "DeviceLink")
    }
}
