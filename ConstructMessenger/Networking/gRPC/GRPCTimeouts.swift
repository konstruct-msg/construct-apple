import Foundation

/// Central registry for gRPC RPC timeouts.
/// Keep these values conservative on cellular/VPN to avoid false timeouts,
/// but bounded so UI doesn't "hang" forever on half-open networks.
enum GRPCTimeouts {
    // Authentication
    static let powChallenge: TimeInterval = 15
    static let registerDevice: TimeInterval = 20
    static let authenticateDevice: TimeInterval = 20
    static let refreshToken: TimeInterval = 15
    static let logout: TimeInterval = 20
    static let recovery: TimeInterval = 30

    // Messaging (interactive)
    static let sendMessage: TimeInterval = 20
    static let editMessage: TimeInterval = 20
    static let endSession: TimeInterval = 20

    // Messaging (background/service)
    static let getPendingMessages: TimeInterval = 30
}

