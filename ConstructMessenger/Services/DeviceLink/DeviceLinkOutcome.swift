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

    /// Stand-only. Production stays on `isPostLinkEnabled`.
    #if DEBUG
    static var debugForceEnabled = false
    #endif

    static var isOffered: Bool {
        if isPostLinkEnabled { return true }
        #if DEBUG
        return debugForceEnabled
        #else
        return false
        #endif
    }
}

/// Whether the UI offers to link a second device at all.
///
/// Multi-device is not a feature this app switches on: a user who links an iPad has it. Until the
/// three-device gate in `MULTIDEVICE_PROTOCOL_PLAN` (прогон 2) reads zero, a linked second device
/// damages the *peer's* single-device clients (`decisions/multidevice-gate-three-asymmetries.md`),
/// and `RecoverAccount` revokes every device before registering the new one, so the link flow is
/// the only door to a second device. Closing it in Release closes the scenario.
///
/// Compile-time, like every other internal surface: `Beta.xcconfig` keeps `DEBUG` so TestFlight
/// stays internal. Not `DeveloperMode.isEnabled` — nothing calls `registerVersionTap`, so that is
/// `false` in every build. The device list and revoke stay reachable regardless: that is how a
/// ghost device is removed, and testers who linked before this gate need it.
enum DeviceLinkOfferPolicy {
    #if DEBUG || INTERNAL_TOOLS
    static let isLinkingOffered = true
    #else
    static let isLinkingOffered = false
    #endif
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
