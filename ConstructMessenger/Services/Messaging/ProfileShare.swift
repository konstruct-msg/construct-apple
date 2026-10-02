//
//  ProfileShare.swift
//  Construct Messenger
//
//  Content type 29: a contact's name and avatar, as a version.
//

import Foundation
import SwiftProtobuf

/// The payload of content type 29 (`Shared_Proto_Core_V1_ProfileShare`): who the sender is to
/// this contact, by its own account.
///
/// Until 2026-10-02 a profile had no type. It was recognised by whether a plaintext parsed as
/// `ProfileShareData`'s hand-written layout, which Android wrote and read on its own; its
/// timestamp was the send time, so a resent old profile looked new; and "no avatar" meant both
/// "removed" and "upload failed". The reading and the apply rule are now fixed for both clients by
/// `knst_profile_share.json`. decisions/profile-share-is-a-typed-versioned-state.md
struct ProfileShare: Equatable {
    struct AvatarRef: Equatable {
        var mediaId: String
        var mediaUrl: String
        /// 32 bytes, AES-256.
        var mediaKey: Data
        var mimeType: String

        static let keyLength = 32

        init(mediaId: String, mediaUrl: String, mediaKey: Data, mimeType: String) {
            self.mediaId = mediaId
            self.mediaUrl = mediaUrl
            self.mediaKey = mediaKey
            self.mimeType = mimeType
        }

        /// What `pendingAvatarRef` holds. Nil for bytes that are not a usable reference.
        init?(stored: Data) {
            guard let ref = try? Shared_Proto_Core_V1_AvatarRef(serializedBytes: stored) else { return nil }
            self.init(proto: ref)
        }

        fileprivate init?(proto ref: Shared_Proto_Core_V1_AvatarRef) {
            guard ref.mediaKey.count == Self.keyLength else { return nil }
            self.init(mediaId: ref.mediaID, mediaUrl: ref.mediaURL, mediaKey: ref.mediaKey, mimeType: ref.mimeType)
        }

        var proto: Shared_Proto_Core_V1_AvatarRef {
            var ref = Shared_Proto_Core_V1_AvatarRef()
            ref.mediaID = mediaId
            ref.mediaURL = mediaUrl
            ref.mediaKey = mediaKey
            ref.mimeType = mimeType
            return ref
        }

        func stored() throws -> Data { try proto.serializedData() }
    }

    enum Avatar: Equatable {
        /// Download this and replace the avatar.
        case set(AvatarRef)
        /// The sender has no avatar now: clear it.
        case removed
        /// Not changed by this profile, or the sender could not upload it: keep what is held.
        case unchanged
    }

    /// What a receiver does with the avatar it holds, once a profile is applied.
    enum AvatarAction: Equatable {
        case download(AvatarRef)
        case clear
        case keep
    }

    var displayName: String
    /// When the sender last changed its name or avatar, ms since the epoch. Not the send time.
    var editedAtMs: UInt64
    var avatar: Avatar

    static func read(_ payload: Data) -> ProfileShare? {
        guard let proto = try? Shared_Proto_Core_V1_ProfileShare(serializedBytes: payload) else { return nil }
        let avatar: Avatar
        switch proto.avatar {
        case .avatarSet(let ref):
            // A key of the wrong length is read as no change, not as a broken profile.
            avatar = AvatarRef(proto: ref).map(Avatar.set) ?? .unchanged
        case .avatarRemoved(true):
            avatar = .removed
        case .avatarRemoved(false), nil:
            avatar = .unchanged
        }
        return ProfileShare(displayName: proto.displayName, editedAtMs: proto.editedAtMs, avatar: avatar)
    }

    func encoded() throws -> Data {
        var proto = Shared_Proto_Core_V1_ProfileShare()
        proto.displayName = displayName
        proto.editedAtMs = editedAtMs
        switch avatar {
        case .set(let ref): proto.avatarSet = ref.proto
        case .removed: proto.avatarRemoved = true
        case .unchanged: break
        }
        return try proto.serializedData()
    }

    /// The name this profile carries, if the sender chose one. Nil for none: empty, or only the
    /// name generated from the sender's id, which Android sends when its user has set no name.
    /// A receiver then shows the contact's username, and the generated name only if there is none
    /// (`User.resolvedDisplayName`).
    func chosenName(of senderId: String) -> String? {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !DisplayNameGenerator.isGenerated(name, for: senderId) else { return nil }
        return name
    }

    /// Whether to apply this profile over the one held, and what then happens to the avatar. Nil:
    /// ignore it whole — it is not newer, so a resend, a redelivery or a reordered queue cannot put
    /// an older name or avatar back. Equal is not newer: the same profile twice applies once.
    ///
    /// `heldEditedAtMs` is `User.profileEditedAtMs`; 0 means nothing typed has been applied.
    func decision(heldEditedAtMs: Int64) -> AvatarAction? {
        guard heldEditedAtMs <= 0 || editedAtMs > UInt64(heldEditedAtMs) else { return nil }
        switch avatar {
        case .set(let ref): return .download(ref)
        case .removed: return .clear
        case .unchanged: return .keep
        }
    }
}
