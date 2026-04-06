//
//  DeviceIdOrdering.swift
//  Construct Messenger
//
//  Stable deviceId ordering for session tie-breaks.
//

import Foundation

enum DeviceIdOrdering {

    /// Returns a stable ordering between two device ids.
    /// Prefers UUID byte ordering when both parse as UUIDs; otherwise falls back to
    /// a literal string compare (stable across devices).
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if let lhsUuid = UUID(uuidString: lhs), let rhsUuid = UUID(uuidString: rhs) {
            return compareUuidBytes(lhsUuid, rhsUuid)
        }
        return lhs.compare(rhs, options: [.literal])
    }

    /// Natural INITIATOR tie-break rule: higher deviceId wins.
    static func isNaturalInitiator(myId: String, peerId: String) -> Bool {
        compare(myId, peerId) == .orderedDescending
    }

    private static func compareUuidBytes(_ lhs: UUID, _ rhs: UUID) -> ComparisonResult {
        withUnsafeBytes(of: lhs.uuid) { lhsBytes in
            withUnsafeBytes(of: rhs.uuid) { rhsBytes in
                for i in 0..<16 {
                    let a = lhsBytes[i]
                    let b = rhsBytes[i]
                    if a == b { continue }
                    return a < b ? .orderedAscending : .orderedDescending
                }
                return .orderedSame
            }
        }
    }
}

