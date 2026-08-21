//
//  ReactionWire.swift
//  Construct Messenger
//
//  Encode `MessageContent.reaction`, and name the two things a send needs that the proto does not
//  carry directly.
//
//  Until 2026-08-21 this file also hand-rolled protobuf varints. `ReactionMessage.timestamp_ms`
//  (field 4) existed in construct-protos but not in the checked-in Swift bindings, so the field was
//  concatenated onto the serialized message on the way out and dug back out of `unknownFields` on
//  the way in. Regenerating the bindings — forced by the `IceCandidate.candidate` type change on
//  the same day — brought the property in, and with it broke that read: the generated decoder now
//  consumes field 4 into `timestampMs`, so it never reaches `unknownFields` and the reader returned
//  0 for every reaction. The workaround and its defect went together.
//

import Foundation

enum ReactionWire {

    static func encode(_ plan: ReactionReducer.SendPlan) -> Data? {
        var reaction = Shared_Proto_Messaging_V1_ReactionMessage()
        reaction.targetMessageID = plan.targetMessageId
        switch plan.incoming {
        case .add(let emoji):
            reaction.emoji = emoji
            reaction.action = .add
        case .remove:
            reaction.emoji = ""
            reaction.action = .remove
        }
        // 0 stays absent on the wire, and the reducer reads absent as "pre-field peer".
        if plan.timestampMs > 0 { reaction.timestampMs = plan.timestampMs }

        var content = Shared_Proto_Messaging_V1_MessageContent()
        content.reaction = reaction
        return try? content.serializedData()
    }

    static func actionRawValue(_ incoming: ReactionReducer.Incoming) -> Int {
        switch incoming {
        case .add: return 1
        case .remove: return 2
        }
    }

    static func emoji(_ incoming: ReactionReducer.Incoming) -> String {
        switch incoming {
        case .add(let emoji): return emoji
        case .remove: return ""
        }
    }
}
