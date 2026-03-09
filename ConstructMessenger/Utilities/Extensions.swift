//
//  Extensions.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import Foundation

extension Date {
    var timestamp: Int64 {
        Int64(self.timeIntervalSince1970)
    }

    static func from(timestamp: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(timestamp))
    }
}

extension String {
    var isValidUsername: Bool {
        let regex = "^[a-zA-Z0-9_]{3,30}$"
        return NSPredicate(format: "SELF MATCHES %@", regex).evaluate(with: self)
    }
}

extension Array {
    /// Safely retrieves an element at the specified index.
    ///
    /// - Parameter index: The index of the element to retrieve.
    /// - Returns: The element at the specified index, or `nil` if the index is out of bounds.
    func get(at index: Int) -> Element? {
        guard index >= 0, index < count else {
            return nil
        }
        return self[index]
    }
}

// MARK: - String + Markdown stripping

extension String {
    /// Returns a plain-text version of the string with inline Markdown markers removed.
    /// Used for chat list preview text where rendered formatting is not needed.
    static func strippingMarkdown(_ text: String) -> String {
        var s = text
        // Bold: **text** or __text__
        s = s.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"__(.+?)__"#, with: "$1", options: .regularExpression)
        // Italic: *text* or _text_  (single marker)
        s = s.replacingOccurrences(of: #"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?<!_)_(?!_)(.+?)(?<!_)_(?!_)"#, with: "$1", options: .regularExpression)
        // Inline code: `text`
        s = s.replacingOccurrences(of: #"`(.+?)`"#, with: "$1", options: .regularExpression)
        // Markdown links: [label](url) → label
        s = s.replacingOccurrences(of: #"\[(.+?)\]\(.+?\)"#, with: "$1", options: .regularExpression)
        return s
    }
}

// MARK: - Error + user-facing message

import GRPCCore

extension Error {
    /// Returns a human-readable message suitable for display in the UI.
    /// Extracts the server message from gRPC RPCError instead of the useless
    /// "The operation couldn't be completed. (GRPCCore.RPCError error N.)" string.
    var userFacingMessage: String {
        if let rpcError = self as? RPCError {
            let msg = rpcError.message
            if !msg.isEmpty { return msg }
            return "Server error (code \(rpcError.code.rawValue))"
        }
        return localizedDescription
    }
}
