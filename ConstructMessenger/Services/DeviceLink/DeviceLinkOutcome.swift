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