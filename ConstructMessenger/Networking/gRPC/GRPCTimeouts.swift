import Foundation

/// Central registry for gRPC RPC timeouts.
/// Keep these values conservative on cellular/VPN to avoid false timeouts,
/// but bounded so UI doesn't "hang" forever on half-open networks.
enum GRPCTimeouts {
    // Authentication
    static let powChallenge: TimeInterval = NetworkTiming.GRPC.Timeouts.powChallenge
    static let registerDevice: TimeInterval = NetworkTiming.GRPC.Timeouts.registerDevice
    static let authenticateDevice: TimeInterval = NetworkTiming.GRPC.Timeouts.authenticateDevice
    static let refreshToken: TimeInterval = NetworkTiming.GRPC.Timeouts.refreshToken
    static let logout: TimeInterval = NetworkTiming.GRPC.Timeouts.logout
    static let recovery: TimeInterval = NetworkTiming.GRPC.Timeouts.recovery
    static let getSenderCertificate: TimeInterval = NetworkTiming.GRPC.Timeouts.recovery

    // Privacy Pass
    static let issueTokens: TimeInterval = NetworkTiming.GRPC.Timeouts.recovery

    // VEIL capability renewal (in-band, short unary call)
    static let issueVeilCapability: TimeInterval = NetworkTiming.GRPC.Timeouts.refreshToken

    // Device linking
    static let initiateDeviceLink: TimeInterval = NetworkTiming.GRPC.Timeouts.initiateDeviceLink
    static let confirmDeviceLink: TimeInterval = NetworkTiming.GRPC.Timeouts.confirmDeviceLink
    static let listDevices: TimeInterval = NetworkTiming.GRPC.Timeouts.listDevices
    static let revokeDevice: TimeInterval = NetworkTiming.GRPC.Timeouts.revokeDevice

    // Messaging (interactive)
    static let sendMessage: TimeInterval = NetworkTiming.GRPC.Timeouts.sendMessage
    static let editMessage: TimeInterval = NetworkTiming.GRPC.Timeouts.editMessage
    static let endSession: TimeInterval = NetworkTiming.GRPC.Timeouts.endSession

    // Messaging (background/service)
    static let getPendingMessages: TimeInterval = NetworkTiming.GRPC.Timeouts.getPendingMessages

    // Key service (session init / rotations)
    static let getPreKeyBundle: TimeInterval = NetworkTiming.GRPC.Timeouts.getPreKeyBundle
    static let getPreKeyBundles: TimeInterval = NetworkTiming.GRPC.Timeouts.getPreKeyBundles
    static let uploadPreKeys: TimeInterval = NetworkTiming.GRPC.Timeouts.uploadPreKeys
    static let getPreKeyCount: TimeInterval = NetworkTiming.GRPC.Timeouts.getPreKeyCount
    static let rotateSignedPreKey: TimeInterval = NetworkTiming.GRPC.Timeouts.rotateSignedPreKey
    static let getIdentityKey: TimeInterval = NetworkTiming.GRPC.Timeouts.getIdentityKey

    // User
    static let getUserProfile: TimeInterval = NetworkTiming.GRPC.Timeouts.getUserProfile
    static let updateUserProfile: TimeInterval = NetworkTiming.GRPC.Timeouts.updateUserProfile
    static let usernameAvailability: TimeInterval = NetworkTiming.GRPC.Timeouts.usernameAvailability
    static let setDiscoverable: TimeInterval = NetworkTiming.GRPC.Timeouts.getUserProfile   // same tier
    static let findUser: TimeInterval = NetworkTiming.GRPC.Timeouts.getUserProfile           // same tier
    static let sendContactRequest: TimeInterval = NetworkTiming.GRPC.Timeouts.getUserProfile
    static let getContactRequests: TimeInterval = NetworkTiming.GRPC.Timeouts.getUserProfile
    static let respondToContactRequest: TimeInterval = NetworkTiming.GRPC.Timeouts.getUserProfile
    static let deleteAccount: TimeInterval = NetworkTiming.GRPC.Timeouts.deleteAccount
    static let blockUser: TimeInterval = NetworkTiming.GRPC.Timeouts.blockUser
    static let unblockUser: TimeInterval = NetworkTiming.GRPC.Timeouts.unblockUser

    // Invites
    static let generateInvite: TimeInterval = NetworkTiming.GRPC.Timeouts.generateInvite
    static let acceptInvite: TimeInterval = NetworkTiming.GRPC.Timeouts.acceptInvite
    static let listInvites: TimeInterval = NetworkTiming.GRPC.Timeouts.listInvites
    static let revokeInvite: TimeInterval = NetworkTiming.GRPC.Timeouts.revokeInvite

    // Sentinel / trust
    static let reportSpam: TimeInterval = NetworkTiming.GRPC.Timeouts.reportSpam
    static let getTrustStatus: TimeInterval = NetworkTiming.GRPC.Timeouts.getTrustStatus
    static let checkSendPermission: TimeInterval = NetworkTiming.GRPC.Timeouts.checkSendPermission

    // Notifications
    static let registerDeviceToken: TimeInterval = NetworkTiming.GRPC.Timeouts.registerDeviceToken
    static let registerVoipToken: TimeInterval = NetworkTiming.GRPC.Timeouts.registerVoipToken
    static let unregisterVoipToken: TimeInterval = NetworkTiming.GRPC.Timeouts.unregisterVoipToken
    static let unregisterDeviceToken: TimeInterval = NetworkTiming.GRPC.Timeouts.unregisterDeviceToken

    // Media
    static let downloadMedia: TimeInterval = NetworkTiming.GRPC.Timeouts.downloadMedia
    static let uploadMedia: TimeInterval = NetworkTiming.GRPC.Timeouts.uploadMedia

    // Calls (signaling)
    static let getTurnCredentials: TimeInterval = NetworkTiming.GRPC.Timeouts.getTurnCredentials
    static let initiateCall: TimeInterval = NetworkTiming.GRPC.Timeouts.initiateCall
}
