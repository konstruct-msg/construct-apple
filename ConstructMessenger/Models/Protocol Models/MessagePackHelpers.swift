//
//  MessagePackHelpers.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 15.12.2025.
//
import Foundation

// TODO: Replace with Protobuf serialization in Phase 6
struct MessagePackHelper {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    static func decode<T: Decodable>(from data: Data) throws -> T {
        try JSONDecoder().decode(T.self, from: data)
    }
}