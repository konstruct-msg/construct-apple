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