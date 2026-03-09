//
//  ServerMessage.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import Foundation

// MARK: - Server → Client Messages
enum ServerMessage: Codable {
    case registerSuccess(RegisterSuccessData)
    case loginSuccess(LoginSuccessData)
    case connectSuccess(ConnectSuccessData)
    case sessionExpired
    case publicKeyBundle(PublicKeyBundleData)
    case message(ChatMessage)
    case ack(AckData)
    case keyRotationSuccess
    case error(ErrorData)
    case logoutSuccess
    case deleteAccountSuccess
    case offlineMessages(OfflineMessagesData)

    // MARK: - Codable Implementation
    
    private enum CodingKeys: String, CodingKey {
        case type
        case payload
    }
    
    private enum MessageType: String, Codable {
        case registerSuccess, loginSuccess, connectSuccess, sessionExpired, publicKeyBundle, message, ack, keyRotationSuccess, error, logoutSuccess, deleteAccountSuccess, offlineMessages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(MessageType.self, forKey: .type)
        
        switch type {
        case .registerSuccess:
            let payload = try container.decode(RegisterSuccessData.self, forKey: .payload)
            self = .registerSuccess(payload)
        case .loginSuccess:
            let payload = try container.decode(LoginSuccessData.self, forKey: .payload)
            self = .loginSuccess(payload)
        case .connectSuccess:
            let payload = try container.decode(ConnectSuccessData.self, forKey: .payload)
            self = .connectSuccess(payload)
        case .sessionExpired:
            self = .sessionExpired
        case .publicKeyBundle:
            let payload = try container.decode(PublicKeyBundleData.self, forKey: .payload)
            self = .publicKeyBundle(payload)
        case .message:
            let payload = try container.decode(ChatMessage.self, forKey: .payload)
            self = .message(payload)
        case .ack:
            let payload = try container.decode(AckData.self, forKey: .payload)
            self = .ack(payload)
        case .keyRotationSuccess:
            self = .keyRotationSuccess
        case .error:
            let payload = try container.decode(ErrorData.self, forKey: .payload)
            self = .error(payload)
        case .logoutSuccess:
            self = .logoutSuccess
        case .deleteAccountSuccess:
            self = .deleteAccountSuccess
        case .offlineMessages:
            let payload = try container.decode(OfflineMessagesData.self, forKey: .payload)
            self = .offlineMessages(payload)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .registerSuccess(let data):
            try container.encode(MessageType.registerSuccess, forKey: .type)
            try container.encode(data, forKey: .payload)
        case .loginSuccess(let data):
            try container.encode(MessageType.loginSuccess, forKey: .type)
            try container.encode(data, forKey: .payload)
        case .connectSuccess(let data):
            try container.encode(MessageType.connectSuccess, forKey: .type)
            try container.encode(data, forKey: .payload)
        case .sessionExpired:
            try container.encode(MessageType.sessionExpired, forKey: .type)
        case .publicKeyBundle(let data):
            try container.encode(MessageType.publicKeyBundle, forKey: .type)
            try container.encode(data, forKey: .payload)
        case .message(let data):
            try container.encode(MessageType.message, forKey: .type)
            try container.encode(data, forKey: .payload)
        case .ack(let data):
            try container.encode(MessageType.ack, forKey: .type)
            try container.encode(data, forKey: .payload)
        case .keyRotationSuccess:
            try container.encode(MessageType.keyRotationSuccess, forKey: .type)
        case .error(let data):
            try container.encode(MessageType.error, forKey: .type)
            try container.encode(data, forKey: .payload)
        case .logoutSuccess:
            try container.encode(MessageType.logoutSuccess, forKey: .type)
        case .deleteAccountSuccess:
            try container.encode(MessageType.deleteAccountSuccess, forKey: .type)
        case .offlineMessages(let data):
            try container.encode(MessageType.offlineMessages, forKey: .type)
            try container.encode(data, forKey: .payload)
        }
    }
}

// MARK: - Payload Structs
struct RegisterSuccessData: Codable {
    let userId: String
    let username: String
    let sessionToken: String
    let refreshToken: String  // ✅ NEW
    let expires: Int64
    var iceBridgeCert: String?
}

struct LoginSuccessData: Codable {
    let userId: String
    let username: String
    let sessionToken: String
    let refreshToken: String  // ✅ NEW
    let expires: Int64
}

struct ConnectSuccessData: Codable {
    let userId: String
    let username: String
}


struct AckData: Codable {
    let messageId: String
    let status: String
}

struct ErrorData: Codable {
    let code: String
    let message: String
}

struct OfflineMessagesData: Codable {
    let messages: [ChatMessage]
}