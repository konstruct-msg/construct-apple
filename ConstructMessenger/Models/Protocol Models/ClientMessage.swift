//
//  ClientMessage.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import Foundation

// MARK: - Client → Server Messages
enum ClientMessage: Codable {
    case register(RegisterData)
    case login(LoginData)
    case connect(ConnectData)
    case getPublicKey(GetPublicKeyData)
    case sendMessage(ChatMessage)
    case rotatePrekey(RotatePrekeyData)
    case logout(LogoutData)
    case getOfflineMessages
    case acknowledgeMessage(AcknowledgeMessageData)

    // MARK: - Codable Implementation
    
    private enum CodingKeys: String, CodingKey {
        case type
        case payload
    }

    private enum MessageType: String, Codable {
        case register, login, connect, getPublicKey, sendMessage, rotatePrekey, logout, getOfflineMessages, acknowledgeMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(MessageType.self, forKey: .type)
        switch type {
        case .register:
            let payload = try container.decode(RegisterData.self, forKey: .payload)
            self = .register(payload)
        case .login:
            let payload = try container.decode(LoginData.self, forKey: .payload)
            self = .login(payload)
        case .connect:
            let payload = try container.decode(ConnectData.self, forKey: .payload)
            self = .connect(payload)
        case .getPublicKey:
            let payload = try container.decode(GetPublicKeyData.self, forKey: .payload)
            self = .getPublicKey(payload)
        case .sendMessage:
            let payload = try container.decode(ChatMessage.self, forKey: .payload)
            self = .sendMessage(payload)
        case .rotatePrekey:
            let payload = try container.decode(RotatePrekeyData.self, forKey: .payload)
            self = .rotatePrekey(payload)
        case .logout:
            let payload = try container.decode(LogoutData.self, forKey: .payload)
            self = .logout(payload)
        case .getOfflineMessages:
            self = .getOfflineMessages
        case .acknowledgeMessage:
            let payload = try container.decode(AcknowledgeMessageData.self, forKey: .payload)
            self = .acknowledgeMessage(payload)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .register(let data):
            try container.encode(MessageType.register, forKey: .type)
            try container.encode(data, forKey: .payload)
        case .login(let data):
            try container.encode(MessageType.login, forKey: .type)
            try container.encode(data, forKey: .payload)
        case .connect(let data):
            try container.encode(MessageType.connect, forKey: .type)
            try container.encode(data, forKey: .payload)
        case .getPublicKey(let data):
            try container.encode(MessageType.getPublicKey, forKey: .type)
            try container.encode(data, forKey: .payload)
        case .sendMessage(let data):
            try container.encode(MessageType.sendMessage, forKey: .type)
            try container.encode(data, forKey: .payload)
        case .rotatePrekey(let data):
            try container.encode(MessageType.rotatePrekey, forKey: .type)
            try container.encode(data, forKey: .payload)
        case .logout(let data):
            try container.encode(MessageType.logout, forKey: .type)
            try container.encode(data, forKey: .payload)
        case .getOfflineMessages:
            try container.encode(MessageType.getOfflineMessages, forKey: .type)
        case .acknowledgeMessage(let data):
            try container.encode(MessageType.acknowledgeMessage, forKey: .type)
            try container.encode(data, forKey: .payload)
        }
    }
}

// MARK: - Payload Structs

/// The final bundle that is encoded as part of the client message.
struct UploadableKeyBundle: Codable {
    let masterIdentityKey: String
    let bundleData: String // Base64 encoded JSON string of `BundleData`
    let signature: String
}

/// The data that is signed and included in the `UploadableKeyBundle`.
struct BundleData: Codable {
    let userId: String
    let timestamp: String // ISO8601
    let supportedSuites: [SuiteKeyMaterial]
}

/// Cryptographic materials for a supported cipher suite.
struct SuiteKeyMaterial: Codable {
    let suiteId: UInt16
    let identityKey: String
    let signedPrekey: String
    let oneTimePrekeys: [String]
}

struct RegisterData: Codable {
    let username: String
    let password: String
    let publicKey: UploadableKeyBundle // Changed to native UploadableKeyBundle
}

struct LoginData: Codable {
    let username: String
    let password: String
}

struct ConnectData: Codable {
    let sessionToken: String
}

struct GetPublicKeyData: Codable {
    let userId: String
}

struct RotatePrekeyData: Codable {
    let userId: String
    let update: UploadableKeyBundle // Changed to native UploadableKeyBundle
}

struct LogoutData: Codable {
    let sessionToken: String
}

struct AcknowledgeMessageData: Codable {
    let messageId: String
    let status: String  // "delivered" when recipient receives the message
}