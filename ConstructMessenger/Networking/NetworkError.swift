//
//  NetworkError.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import Foundation

enum NetworkError: Error, LocalizedError {
    case connectionFailed
    case disconnected
    case notConnected          // ✅ NEW: Not connected to server
    case invalidMessage
    case encodingFailed
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .connectionFailed: return "Failed to connect to server"
        case .disconnected: return "Connection lost"
        case .notConnected: return "Not connected to server"
        case .invalidMessage: return "Invalid message format"
        case .encodingFailed: return "Failed to encode message"
        case .decodingFailed: return "Failed to decode message"
        }
    }
}
