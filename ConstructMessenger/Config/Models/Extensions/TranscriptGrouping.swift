//
//  TranscriptGrouping.swift
//  Construct Messenger
//
//  Message grouping logic extracted from ChatView
//  Created on 30.01.2026 (Week 1 refactoring); `Message+Grouping.swift` until the transcript moved
//  to values (2026-10-12).
//

import Foundation

/// What grouping reads of a transcript entry — the list renders `TranscriptEntry`, whose two are
/// fixed for its lifetime; `TranscriptRow` answers it too.
protocol TranscriptGroupable {
    var isSentByMe: Bool { get }
    var safeTimestamp: Date { get }
}

extension TranscriptGroupable {
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
    func isLastInGroup(at index: Int, in messages: [some TranscriptGroupable]) -> Bool {
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
    /// - Returns: ``ChatUIConstants.Shell.betweenGroupSpacing`` at group end,
    ///   ``ChatUIConstants.Shell.withinGroupSpacing`` inside a group
    func spacingAfterMessage(at index: Int, in messages: [some TranscriptGroupable]) -> CGFloat {
        if self.isLastInGroup(at: index, in: messages) {
            return ChatUIConstants.Shell.betweenGroupSpacing
        }
        return ChatUIConstants.Shell.withinGroupSpacing
    }
}
