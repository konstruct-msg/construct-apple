import XCTest
import CoreData
@testable import Construct_Messenger

/// A changed name or avatar goes again to every contact the profile is shared with.
///
/// Until 2026-10-02 it reached none: each send ran in a `Task` holding the view model weakly, and
/// `SettingsViewModel` makes that view model for the one call and lets it go — so by the time the
/// sends ran there was nobody to run them (observed on the three-simulator stand: "Rebroadcasting
/// profile to 2 contact(s)" and then nothing). Before April, a re-entrancy guard let the first
/// contact through and dropped the rest. Mutation: make the rebroadcast fire-and-forget again, or
/// send to contacts in parallel through the guarded entry point — this reddens.
@MainActor
final class ProfileRebroadcastTests: XCTestCase {

    private var savedUserId: String?
    private let me = UUID().uuidString

    override func setUp() {
        super.setUp()
        savedUserId = AuthSessionManager.shared.currentUserId
        AuthSessionManager.shared.updateUserId(me)
    }

    override func tearDown() {
        LocalRepositories.useContactsForTesting(nil)
        if let savedUserId, !savedUserId.isEmpty {
            AuthSessionManager.shared.updateUserId(savedUserId)
        }
        super.tearDown()
    }

    func testRebroadcastReachesEverySharedContactFromAThrowawayViewModel() async {
        let container = PersistenceController(inMemory: true).container
        LocalRepositories.useContactsForTesting(container)
        let context = container.viewContext
        let self_ = User(context: context)
        self_.id = me
        self_.username = "me"
        self_.displayName = "Alice Two"
        var shared: [String] = []
        for i in 0..<3 {
            let contact = User(context: context)
            contact.id = UUID().uuidString
            contact.username = "c\(i)"
            contact.displayName = ""
            contact.amISharingWith = true
            shared.append(contact.id)
        }
        let notShared = User(context: context)
        notShared.id = UUID().uuidString
        notShared.username = "other"
        notShared.displayName = ""
        notShared.amISharingWith = false
        try? context.save()

        var delivered: [(String, String)] = []
        // As SettingsViewModel does it: a view model made for this call and held by nobody else.
        await ProfileShareViewModel(context: context, deliver: { profile, contactId in
            delivered.append((contactId, profile.data.displayName))
            return (true, nil)
        }, pause: { _ in }).rebroadcastProfileToSharedContacts()

        XCTAssertEqual(Set(delivered.map(\.0)), Set(shared), "every contact the profile is shared with, and only those")
        XCTAssertEqual(delivered.count, shared.count, "each once")
        XCTAssertTrue(delivered.allSatisfy { $0.1 == "Alice Two" }, "the current name")
    }

    /// The profile carries when we last edited it, not when it was sent: two rebroadcasts of an
    /// unchanged profile carry the same version, so a contact applies the first and ignores the
    /// second. With no avatar it says "removed" — the state that lets a contact clear one.
    func testTheVersionIsTheEditNotTheSendAndNoAvatarIsRemoved() async {
        let container = PersistenceController(inMemory: true).container
        LocalRepositories.useContactsForTesting(container)
        let context = container.viewContext
        let self_ = User(context: context)
        self_.id = me
        self_.username = "me"
        self_.displayName = "Alice"
        let contact = User(context: context)
        contact.id = UUID().uuidString
        contact.username = "c"
        contact.displayName = ""
        contact.amISharingWith = true
        try? context.save()

        var sent: [ProfileShare] = []
        let vm = ProfileShareViewModel(context: context, deliver: { profile, _ in
            sent.append(profile.data)
            return (true, nil)
        })
        await vm.rebroadcastProfileToSharedContacts()
        try? await Task.sleep(nanoseconds: 5_000_000)
        await vm.rebroadcastProfileToSharedContacts()

        XCTAssertEqual(sent.count, 2)
        XCTAssertGreaterThan(sent[0].editedAtMs, 0, "an unstamped profile is stamped once")
        XCTAssertEqual(sent[0].editedAtMs, sent[1].editedAtMs, "sending again is not an edit")
        XCTAssertEqual(sent[0].avatar, .removed)

        self_.markProfileEdited(now: Date().addingTimeInterval(1))
        try? context.save()
        await vm.rebroadcastProfileToSharedContacts()
        XCTAssertGreaterThan(sent[2].editedAtMs, sent[1].editedAtMs, "an edit is a newer version")
    }

    // MARK: - TODO 144: the avatar must not show whom we share the profile with

    private func sharedContacts(_ count: Int, avatar: Data?, in context: NSManagedObjectContext) -> [String] {
        let self_ = User(context: context)
        self_.id = me
        self_.username = "me"
        self_.displayName = "Alice"
        self_.avatarData = avatar
        var ids: [String] = []
        for i in 0..<count {
            let contact = User(context: context)
            contact.id = UUID().uuidString
            contact.username = "c\(i)"
            contact.displayName = ""
            contact.amISharingWith = true
            ids.append(contact.id)
        }
        try? context.save()
        return ids
    }

    private func jpeg() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).jpegData(withCompressionQuality: 0.8) { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
    }

    /// One object fetched from N connections says "the same thing to these N people". Each contact
    /// gets its own upload, so its own media id.
    func testEachContactGetsItsOwnUploadOfTheAvatar() async {
        let container = PersistenceController(inMemory: true).container
        LocalRepositories.useContactsForTesting(container)
        let context = container.viewContext
        let contacts = sharedContacts(3, avatar: jpeg(), in: context)

        var uploads = 0
        var mediaIds: [String: String] = [:]
        await ProfileShareViewModel(context: context, deliver: { profile, contactId in
            if case .set(let ref) = profile.data.avatar { mediaIds[contactId] = ref.mediaId }
            return (true, nil)
        }, uploadAvatar: { _ in
            uploads += 1
            return AvatarUploadResult(mediaUrl: "u", encryptionKey: Data(repeating: 1, count: 32),
                                      mediaId: UUID().uuidString, hash: "00")
        }, pause: { _ in }).rebroadcastProfileToSharedContacts()

        XCTAssertEqual(uploads, contacts.count)
        XCTAssertEqual(Set(mediaIds.keys), Set(contacts))
        XCTAssertEqual(Set(mediaIds.values).count, contacts.count, "no two contacts share an object")
    }

    /// Sends in one burst say "one account, N recipients, now".
    func testContactsAreSentApart() async {
        let container = PersistenceController(inMemory: true).container
        LocalRepositories.useContactsForTesting(container)
        let context = container.viewContext
        let contacts = sharedContacts(4, avatar: nil, in: context)

        var pauses: [Duration] = []
        await ProfileShareViewModel(context: context, deliver: { _, _ in (true, nil) },
                                    pause: { pauses.append($0) }).rebroadcastProfileToSharedContacts()

        XCTAssertEqual(pauses.count, contacts.count - 1, "between contacts, not before the first")
        let range = ProfileShareViewModel.rebroadcastSpacing
        XCTAssertTrue(pauses.allSatisfy { $0 >= .seconds(range.lowerBound) && $0 <= .seconds(range.upperBound) })
    }

    func testEveryAvatarHasOneLengthAndStillShows() throws {
        let small = jpeg()
        let padded = AvatarPadding.padded(small)
        XCTAssertEqual(padded.count, AvatarPadding.size)
        XCTAssertEqual(padded.prefix(small.count), small, "the picture itself is untouched")
        let image = try XCTUnwrap(UIImage(data: padded), "a decoder stops at the end of the image")
        XCTAssertEqual(image.size, UIImage(data: small)?.size, "the same picture as before padding")

        let large = Data(count: AvatarPadding.size + 1)
        XCTAssertEqual(AvatarPadding.padded(large).count, 2 * AvatarPadding.size)
        XCTAssertEqual(AvatarPadding.padded(Data(count: AvatarPadding.size)).count, AvatarPadding.size)
    }

    /// Removing our photo is an edit: the avatar goes, the version moves, and the profile that
    /// follows says "removed" — the state a contact needs to clear the one it holds.
    func testRemovingOurAvatarIsAnEditThatTravelsAsRemoved() async {
        let container = PersistenceController(inMemory: true).container
        LocalRepositories.useContactsForTesting(container)
        let context = container.viewContext
        let self_ = User(context: context)
        self_.id = me
        self_.username = "me"
        self_.displayName = "Alice"
        self_.avatarData = Data([1, 2, 3])
        self_.profileEditedAtMs = 1
        try? context.save()

        let settings = SettingsViewModel()
        settings.setContext(context)
        settings.userId = me
        settings.removeAvatar()
        context.refresh(self_, mergeChanges: false)

        XCTAssertNil(self_.avatarData)
        XCTAssertGreaterThan(self_.profileEditedAtMs, 1, "a removal is a newer version, or contacts would ignore it")
        let profile = await ProfileShareViewModel(context: context).prepareProfile()
        XCTAssertEqual(profile?.data.avatar, .removed)
    }
}
