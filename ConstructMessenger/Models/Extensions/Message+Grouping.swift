//
//  Message+Grouping.swift
//  Construct Messenger
//
//  Message grouping logic extracted from ChatView
//  Created on 30.01.2026 (Week 1 refactoring)
//

import Foundation

extension Message {
    /// Determines if this message is the last in a group of consecutive messages from the same sender
    ///
    /// Messages are grouped when:
    /// - Sent by the same user (isSentByMe matches)
    /// - Within 5 minutes of each other
    ///
    /// - Parameters:
    ///   - index: Index of this message in the array
    ///   - messages: Array of messages (newest-first order expected)
    /// - Returns: `true` if this is the last message in the group
    func isLastInGroup(at index: Int, in messages: [Message]) -> Bool {
        // If this is the last message in the array, it's always the last in its group
        guard index < messages.count - 1 else {
            return true
        }

        let nextMessage = messages[index + 1]

        // Different sender = end of group
        if self.isSentByMe != nextMessage.isSentByMe {
            return true
        }

        // If more than 5 minutes apart, start a new group
        let timeDifference = nextMessage.safeTimestamp.timeIntervalSince(self.safeTimestamp)
        if timeDifference > 300 { // 5 minutes = 300 seconds
            return true
        }

        return false
    }
    
    /// Returns appropriate spacing after this message in the UI
    ///
    /// - Parameters:
    ///   - index: Index of this message in the array
    ///   - messages: Array of messages (newest-first order expected)
    /// - Returns: Spacing in points (12pt for group end, 4pt within group)
    func spacingAfterMessage(at index: Int, in messages: [Message]) -> CGFloat {
        // If this is the last in group, use larger spacing
        if self.isLastInGroup(at: index, in: messages) {
            return 12
        }

        // Otherwise, use compact spacing within the group
        return 4
    }
}

// MARK: - Array Extension for Convenience

extension Array where Element == Message {
    /// Helper to check if a message at an index is the last in its group
    func isLastInGroup(at index: Int) -> Bool {
        guard index < count else { return true }
        return self[index].isLastInGroup(at: index, in: self)
    }
    
    /// Helper to get spacing after a message at an index
    func spacingAfterMessage(at index: Int) -> CGFloat {
        guard index < count else { return 12 }
        return self[index].spacingAfterMessage(at: index, in: self)
    }
}
