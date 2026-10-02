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
        if let savedUserId, !savedUserId.isEmpty {
            AuthSessionManager.shared.updateUserId(savedUserId)
        }
        super.tearDown()
    }

    func testRebroadcastReachesEverySharedContactFromAThrowawayViewModel() async {
        let context = PersistenceController(inMemory: true).container.viewContext
        let self_ = User(context: context)
        self_.id = me
        self_.username = "me"
        self_.displayName = "Alice Two"
        var shared: [String] = []
        for i in 0..<3 {
            let contact = User(context: context)
            contact.id = UUID().uuidString
            contact.username = "c\(i)"
            contact.amISharingWith = true
            shared.append(contact.id)
        }
        let notShared = User(context: context)
        notShared.id = UUID().uuidString
        notShared.username = "other"
        notShared.amISharingWith = false
        try? context.save()

        var delivered: [(String, String)] = []
        // As SettingsViewModel does it: a view model made for this call and held by nobody else.
        await ProfileShareViewModel(context: context, deliver: { profile, contactId in
            delivered.append((contactId, profile.data.displayName))
            return (true, nil)
        }).rebroadcastProfileToSharedContacts()

        XCTAssertEqual(Set(delivered.map(\.0)), Set(shared), "every contact the profile is shared with, and only those")
        XCTAssertEqual(delivered.count, shared.count, "each once")
        XCTAssertTrue(delivered.allSatisfy { $0.1 == "Alice Two" }, "the current name")
    }
}
