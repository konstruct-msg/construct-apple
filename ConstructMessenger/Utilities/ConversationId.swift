// ConversationId.swift
// Construct Messenger
//
// Canonical conversation ID generation.
// Proto spec (envelope.proto):
//   conversation_id: "direct:{user1}:{user2}" or "group:{group_id}"
// For 1:1 chats the two user IDs are sorted lexicographically so both
// parties produce the same ID regardless of who initiates.

enum ConversationId {
    /// Canonical 1-to-1 conversation ID.
    /// Sorted so the result is the same on both devices.
    static func direct(myUserId: String, theirUserId: String) -> String {
        let (a, b) = myUserId < theirUserId
            ? (myUserId, theirUserId)
            : (theirUserId, myUserId)
        return "direct:\(a):\(b)"
    }
}
