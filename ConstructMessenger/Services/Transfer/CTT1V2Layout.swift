//
//  CTT1V2Layout.swift
//  Construct Messenger
//
//  Field sizes for CTT1 v2 / CTHF. Opening and reply lengths are sums of
//  these fields — a literal 6575 / 5421 in production code is a defect.
//

import Foundation

enum CTT1V2Layout {
    static let magic = Data([0x43, 0x54, 0x54, 0x31]) // "CTT1"
    static let versionV1: UInt8 = 0x01
    static let versionV2: UInt8 = 0x02

    static let magicCount = 4
    static let versionCount = 1
    static let ephPubCount = 32
    static let typeCount = 1
    static let payloadLenCount = 8
    static let identityPubCount = 32
    static let ed25519PubCount = 32
    static let mlDsa65PubCount = 1952
    static let hybridPubCount = ed25519PubCount + mlDsa65PubCount
    static let snapshotIdCount = 16
    static let deviceIdCount = 16
    static let kyberKeyIdCount = 4
    static let kemCtCount = 1088
    static let ed25519SigCount = 64
    static let mlDsa65SigCount = 3309
    static let hybridSigCount = ed25519SigCount + mlDsa65SigCount

    static let prefixCount =
        magicCount + versionCount + ephPubCount + typeCount + payloadLenCount

    static let openingAfterPrefixCount =
        identityPubCount + hybridPubCount + snapshotIdCount
        + deviceIdCount + deviceIdCount + kyberKeyIdCount
        + kemCtCount + hybridSigCount

    static let openingCount = prefixCount + openingAfterPrefixCount
    static let replyCount =
        ephPubCount + identityPubCount + hybridPubCount + hybridSigCount

    static let maxPayloadBytes: UInt64 = 2 * 1024 * 1024 * 1024

    static let senderTag = Data("ctt1v2-s".utf8)
    static let receiverTag = Data("ctt1v2-r".utf8)
    static let channelSalt = Data("construct_transfer_v2".utf8)
    static let fileSalt = Data("construct_history_file_v1".utf8)
}
