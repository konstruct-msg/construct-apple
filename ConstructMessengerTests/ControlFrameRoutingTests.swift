import XCTest
import CoreData
@testable import Construct_Messenger

/// A control frame the core named (core 0.30, `controlFrameDecrypted`) is carried out by account,
/// and a blocked contact's is dropped.
///
/// Until 0.30 a sealed receipt, card or profile left the core as `messageDecrypted` and this app
/// parsed the KNST frame itself on the body path, after the block check. Now the core names it;
/// what must not change is who it is filed under — the action names the peer by *device*, the
/// handlers file by *account* (the same mistake dropped every incoming call signal on 2026-10-02,
/// construct-ios #49) — and that a blocked contact still cannot reach us through one.
@MainActor
final class ControlFrameRoutingTests: XCTestCase {

    private let device = "6f5e37ac6f5e37ac6f5e37ac6f5e37ac"
    private var context: NSManagedObjectContext!
    private var contact: User!

    override func setUp() {
        super.setUp()
        let container = PersistenceController(inMemory: true).container
        LocalRepositories.useContactsForTesting(container)
        context = container.viewContext
        contact = User(context: context)
        contact.id = UUID().uuidString
        contact.username = "alice"
        contact.displayName = "Mystic Parrot"
        try! context.save()
    }

    override func tearDown() {
        LocalRepositories.useContactsForTesting(nil)
        super.tearDown()
    }

    private func profileFrame(_ name: String, editedAt: UInt64) throws -> CfeAction {
        let body = try ProfileShare(displayName: name, editedAtMs: editedAt, avatar: .unchanged).encoded()
        return .controlFrameDecrypted(contactId: device, messageId: "m-\(editedAt)", contentType: 29, body: body)
    }

    /// The profile lands on the account the router names, though the action names a device.
    /// Mutation: pass the action's contact id instead of `otherUserId` — this reddens.
    func testAProfileFrameIsAppliedToTheAccount() throws {
        MessageRouter().handleControlFrames(in: [try profileFrame("Alice One", editedAt: 10)], messageId: "m-10", from: contact.id, in: context)
        XCTAssertEqual(try LocalRepositories.contacts.contact(contact.id)?.displayName, "Alice One")
    }

    /// Mutation: drop the block check in `handleControlFrames` — this reddens.
    func testABlockedContactsFrameIsDropped() throws {
        contact.isBlocked = true
        try context.save()
        MessageRouter().handleControlFrames(in: [try profileFrame("Alice One", editedAt: 10)], messageId: "m-10", from: contact.id, in: context)
        XCTAssertEqual(contact.displayName, "Mystic Parrot")
    }

    func testTheVerdictAndTheExecutorAgreeItIsTheRoutersToCarryOut() throws {
        let action = try profileFrame("x", editedAt: 1)
        XCTAssertEqual(OrchestratorActionPlan.routingVerdict(from: [action]), .controlFrameDecrypted)
        XCTAssertEqual(SessionActionExecutor.routerBoundName(action), "controlFrameDecrypted")
        XCTAssertEqual(MessageRouter.controlFrames(in: [action]).map(\.contentType), [29])
    }
}
