import XCTest
import CoreData
@testable import Construct_Messenger

/// Content type 29: a profile reads and applies as `knst_profile_share.json` says, which Android
/// reads too.
///
/// Until 2026-10-02 a profile had no type and no version: the last one to arrive won, so a resent
/// old profile put an old name back; "no avatar" meant both "removed" and "upload failed", so no
/// avatar was ever cleared; and nothing kept the avatar reference, so a failed download was never
/// retried. decisions/profile-share-is-a-typed-versioned-state.md
@MainActor
final class ProfileShareTests: XCTestCase {

    // MARK: - Vectors

    private struct Vectors: Decodable {
        let decode: [DecodeCase]
        let apply: [ApplyCase]
    }

    private struct DecodeCase: Decodable {
        let name: String
        let payload: String
        let displayName: String
        let editedAtMs: UInt64
        let avatar: AvatarState

        enum CodingKeys: String, CodingKey {
            case name, payload, avatar
            case displayName = "display_name"
            case editedAtMs = "edited_at_ms"
        }
    }

    /// `{"set": {...}}`, `"removed"` or `"unchanged"`.
    private enum AvatarState: Decodable {
        case set(mediaId: String, mediaUrl: String, mediaKey: String, mimeType: String)
        case removed
        case unchanged

        private struct SetFields: Decodable {
            let mediaId: String
            let mediaUrl: String
            let mediaKey: String
            let mimeType: String
            enum CodingKeys: String, CodingKey {
                case mediaId = "media_id", mediaUrl = "media_url", mediaKey = "media_key", mimeType = "mime_type"
            }
        }

        init(from decoder: Decoder) throws {
            if let word = try? decoder.singleValueContainer().decode(String.self) {
                switch word {
                case "removed": self = .removed
                case "unchanged": self = .unchanged
                default: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: word))
                }
                return
            }
            let set = try decoder.container(keyedBy: AnyKey.self).decode(SetFields.self, forKey: AnyKey("set"))
            self = .set(mediaId: set.mediaId, mediaUrl: set.mediaUrl, mediaKey: set.mediaKey, mimeType: set.mimeType)
        }
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private struct ApplyCase: Decodable {
        let name: String
        let heldEditedAtMs: Int64?
        let editedAtMs: UInt64
        let avatar: String
        let result: String
        let avatarAction: String?

        enum CodingKeys: String, CodingKey {
            case name, avatar, result
            case heldEditedAtMs = "held_edited_at_ms"
            case editedAtMs = "edited_at_ms"
            case avatarAction = "avatar_action"
        }
    }

    /// The vendored copy, located from this file — adding a resource to the test target is a
    /// project-file change.
    private func loadVectors() throws -> Vectors {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConstructMessenger/Networking/gRPC/Generated/conformance/knst_profile_share.json")
        let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
        // Empty lists would make every loop below pass by never running.
        XCTAssertGreaterThanOrEqual(vectors.decode.count, 4, "vectors look truncated")
        XCTAssertGreaterThanOrEqual(vectors.apply.count, 6, "vectors look truncated")
        return vectors
    }

    private func hex(_ s: String) -> Data {
        var data = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            data.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return data
    }

    func testEveryDecodeVectorReadsAsStated() throws {
        for c in try loadVectors().decode {
            let profile = try XCTUnwrap(ProfileShare.read(hex(c.payload)), c.name)
            XCTAssertEqual(profile.displayName, c.displayName, c.name)
            XCTAssertEqual(profile.editedAtMs, c.editedAtMs, c.name)
            switch c.avatar {
            case .set(let mediaId, let mediaUrl, let mediaKey, let mimeType):
                XCTAssertEqual(profile.avatar, .set(.init(mediaId: mediaId, mediaUrl: mediaUrl, mediaKey: hex(mediaKey), mimeType: mimeType)), c.name)
            case .removed:
                XCTAssertEqual(profile.avatar, .removed, c.name)
            case .unchanged:
                XCTAssertEqual(profile.avatar, .unchanged, c.name)
            }
        }
    }

    /// What we send is byte-for-byte what `protoc` makes of the same profile, for every case
    /// whose reading is not lossy — so Android reads our bytes as the vectors say.
    func testEncodingMatchesTheVectorBytes() throws {
        for c in try loadVectors().decode where c.name != "short_key_is_unchanged" {
            let profile = try XCTUnwrap(ProfileShare.read(hex(c.payload)), c.name)
            XCTAssertEqual(try profile.encoded(), hex(c.payload), c.name)
        }
    }

    func testEveryApplyVectorDecidesAsStated() throws {
        let ref = ProfileShare.AvatarRef(mediaId: "m", mediaUrl: "u", mediaKey: Data(repeating: 7, count: 32), mimeType: "image/jpeg")
        for c in try loadVectors().apply {
            let avatar: ProfileShare.Avatar = switch c.avatar {
            case "set": .set(ref)
            case "removed": .removed
            default: .unchanged
            }
            let decision = ProfileShare(displayName: "x", editedAtMs: c.editedAtMs, avatar: avatar)
                .decision(heldEditedAtMs: c.heldEditedAtMs ?? 0)
            switch (c.result, c.avatarAction) {
            case ("ignore", _): XCTAssertNil(decision, c.name)
            case ("apply", "download"): XCTAssertEqual(decision, .download(ref), c.name)
            case ("apply", "clear"): XCTAssertEqual(decision, .clear, c.name)
            case ("apply", "keep"): XCTAssertEqual(decision, .keep, c.name)
            default: XCTFail("\(c.name): unknown result \(c.result)/\(c.avatarAction ?? "nil")")
            }
        }
    }

    // MARK: - Applying to a contact

    private var context: NSManagedObjectContext!
    private var contact: User!

    override func setUp() {
        super.setUp()
        context = PersistenceController(inMemory: true).container.viewContext
        contact = User(context: context)
        contact.id = UUID().uuidString
        contact.username = "alice"
        contact.displayName = "Mystic Parrot"
        contact.avatarData = Data([1, 2, 3])
        try? context.save()
    }

    private func apply(_ profile: ProfileShare) -> [NSManagedObjectID] {
        var started: [NSManagedObjectID] = []
        ProfileSharingManager.shared.apply(profile, from: contact.id, in: context) { started.append($0) }
        return started
    }

    private let ref = ProfileShare.AvatarRef(mediaId: "m-2", mediaUrl: "u", mediaKey: Data(repeating: 9, count: 32), mimeType: "image/jpeg")

    func testANewerProfileRenamesAndQueuesItsAvatar() throws {
        let started = apply(ProfileShare(displayName: "Alice One", editedAtMs: 100, avatar: .set(ref)))
        XCTAssertEqual(contact.displayName, "Alice One")
        XCTAssertEqual(contact.profileEditedAtMs, 100)
        XCTAssertEqual(contact.pendingAvatarRef.flatMap(ProfileShare.AvatarRef.init(stored:)), ref,
                       "the reference is kept until the avatar arrives — that is what a retry reads")
        XCTAssertEqual(started, [contact.objectID])
    }

    /// The defect the version exists for: a resent or reordered older profile put the old name back.
    func testAnOlderProfileChangesNothing() {
        _ = apply(ProfileShare(displayName: "Alice Two", editedAtMs: 200, avatar: .unchanged))
        let started = apply(ProfileShare(displayName: "Alice One", editedAtMs: 100, avatar: .removed))
        XCTAssertEqual(contact.displayName, "Alice Two")
        XCTAssertEqual(contact.profileEditedAtMs, 200)
        XCTAssertEqual(contact.avatarData, Data([1, 2, 3]), "an ignored profile does not clear the avatar either")
        XCTAssertTrue(started.isEmpty)
    }

    func testRemovedClearsTheAvatarAndAnythingPending() {
        _ = apply(ProfileShare(displayName: "Alice", editedAtMs: 100, avatar: .set(ref)))
        _ = apply(ProfileShare(displayName: "Alice", editedAtMs: 101, avatar: .removed))
        XCTAssertNil(contact.avatarData)
        XCTAssertNil(contact.pendingAvatarRef, "a removed avatar must not arrive later from an old reference")
    }

    func testUnchangedKeepsTheAvatar() {
        _ = apply(ProfileShare(displayName: "Alice", editedAtMs: 100, avatar: .unchanged))
        XCTAssertEqual(contact.avatarData, Data([1, 2, 3]))
        XCTAssertNil(contact.pendingAvatarRef)
    }

    /// Once a typed profile is held, the old untyped layout — whose timestamp is the send time — is
    /// ignored: it cannot be ordered against a version.
    func testAnUntypedProfileIsIgnoredOnceATypedOneIsHeld() {
        _ = apply(ProfileShare(displayName: "Alice Two", editedAtMs: 200, avatar: .unchanged))
        let legacy = ProfileShareData(displayName: "Alice Old", avatarMediaId: nil, avatarMediaUrl: nil,
                                      avatarMediaKey: nil, avatarMediaType: nil, timestamp: Int64(Date().timeIntervalSince1970))
        ProfileSharingManager.shared.handleProfileMessage(legacy, from: contact.id, in: context)
        XCTAssertEqual(contact.displayName, "Alice Two")
    }

    func testAnUntypedProfileStillAppliesToAContactWithoutATypedOne() {
        let legacy = ProfileShareData(displayName: "Alice Old", avatarMediaId: nil, avatarMediaUrl: nil,
                                      avatarMediaKey: nil, avatarMediaType: nil, timestamp: 1)
        ProfileSharingManager.shared.handleProfileMessage(legacy, from: contact.id, in: context)
        XCTAssertEqual(contact.displayName, "Alice Old")
    }

    // MARK: - No chosen name

    /// The defect of 2026-10-02: Android sends its generated name when its user set none, and it
    /// replaced the username the invite gave us.
    func testAGeneratedNameDoesNotReplaceTheUsername() {
        contact.displayName = "alice"
        let generated = DisplayNameGenerator.generate(from: contact.id).lowercased()
        _ = apply(ProfileShare(displayName: generated, editedAtMs: 100, avatar: .unchanged))
        XCTAssertEqual(contact.resolvedDisplayName, "alice")
        XCTAssertEqual(contact.profileEditedAtMs, 100, "the profile still applies — only the name is none")
    }

    func testAnEmptyNameShowsTheUsername() {
        _ = apply(ProfileShare(displayName: "Alice One", editedAtMs: 100, avatar: .unchanged))
        _ = apply(ProfileShare(displayName: "", editedAtMs: 101, avatar: .unchanged))
        XCTAssertEqual(contact.resolvedDisplayName, "alice", "a newer profile with no name drops the old one")
    }

    func testAnUntypedGeneratedNameDoesNotReplaceTheUsername() {
        contact.displayName = "alice"
        let legacy = ProfileShareData(displayName: DisplayNameGenerator.generate(from: contact.id), avatarMediaId: nil,
                                      avatarMediaUrl: nil, avatarMediaKey: nil, avatarMediaType: nil, timestamp: 1)
        ProfileSharingManager.shared.handleProfileMessage(legacy, from: contact.id, in: context)
        XCTAssertEqual(contact.resolvedDisplayName, "alice")
    }

    /// Rows already overwritten before the fix: the generated name held is skipped for the username.
    func testAGeneratedNameAlreadyHeldShowsTheUsername() {
        contact.displayName = DisplayNameGenerator.generate(from: contact.id)
        XCTAssertEqual(contact.resolvedDisplayName, "alice")
        contact.username = ""
        XCTAssertEqual(contact.resolvedDisplayName, DisplayNameGenerator.generate(from: contact.id))
    }
}
