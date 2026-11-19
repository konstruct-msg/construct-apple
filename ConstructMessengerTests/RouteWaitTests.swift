import XCTest
import CoreData
@testable import Construct_Messenger

/// todo 320: with VEIL on and no tunnel, the queue waits once per peer instead of failing on every
/// trigger, and a reaction or edit waits for the route and gets one more try.
final class RouteWaitGateTests: XCTestCase {

    func testARouteSendsNow() {
        var gate = RouteWaitGate()
        XCTAssertEqual(gate.admit("peer", routed: true), .now)
        XCTAssertTrue(gate.isEmpty)
    }

    func testWithoutARouteTheFirstTriggerWaitsAndTheRestJoinIt() {
        var gate = RouteWaitGate()
        XCTAssertEqual(gate.admit("peer", routed: false), .startWaiting)
        XCTAssertEqual(gate.admit("peer", routed: false), .joinWaiting)
        XCTAssertEqual(gate.admit("peer", routed: false), .joinWaiting)
    }

    func testEachPeerHasItsOwnWait() {
        var gate = RouteWaitGate()
        XCTAssertEqual(gate.admit("a", routed: false), .startWaiting)
        XCTAssertEqual(gate.admit("b", routed: false), .startWaiting)
    }

    func testOnlyARouteSendsNow() {
        XCTAssertTrue(RouteWaitGate.Admission.now.sendsNow)
        XCTAssertFalse(RouteWaitGate.Admission.startWaiting.sendsNow)
        XCTAssertFalse(RouteWaitGate.Admission.joinWaiting.sendsNow)
    }

    func testAFinishedWaitLetsTheNextTriggerWaitAgain() {
        var gate = RouteWaitGate()
        _ = gate.admit("peer", routed: false)
        gate.finished("peer")
        XCTAssertTrue(gate.isEmpty)
        XCTAssertEqual(gate.admit("peer", routed: false), .startWaiting)
    }
}

final class ActionSendTests: XCTestCase {
    private struct Transport: Error {}
    private struct Refused: Error {}

    private final class Script: @unchecked Sendable {
        var waits = 0
        var sends = 0
        var routeComes = true
        var failures: [Error] = []

        func wait() async -> Bool {
            waits += 1
            return routeComes
        }

        func send() async throws -> String {
            sends += 1
            if !failures.isEmpty { throw failures.removeFirst() }
            return "sent"
        }
    }

    private func run(_ script: Script) async throws -> String {
        try await ActionSend.whenRouted(
            waitForRoute: { await script.wait() },
            isRetryable: { $0 is Transport },
            { try await script.send() }
        )
    }

    func testItWaitsForTheRouteThenSendsOnce() async throws {
        let script = Script()
        let result = try await run(script)
        XCTAssertEqual(result, "sent")
        XCTAssertEqual(script.waits, 1)
        XCTAssertEqual(script.sends, 1)
    }

    func testATransportFailureGetsOneMoreTryAfterTheRoute() async throws {
        let script = Script()
        script.failures = [Transport()]
        let result = try await run(script)
        XCTAssertEqual(result, "sent")
        XCTAssertEqual(script.waits, 2)
        XCTAssertEqual(script.sends, 2)
    }

    func testAnAnswerFromTheServerIsNotRetried() async {
        let script = Script()
        script.failures = [Refused()]
        do {
            _ = try await run(script)
            XCTFail("a refusal must reach the caller")
        } catch {
            XCTAssertTrue(error is Refused)
        }
        XCTAssertEqual(script.sends, 1)
        XCTAssertEqual(script.waits, 1)
    }

    func testTheSecondTransportFailureReachesTheCaller() async {
        let script = Script()
        script.failures = [Transport(), Transport()]
        do {
            _ = try await run(script)
            XCTFail("two failures must reach the caller")
        } catch {
            XCTAssertTrue(error is Transport)
        }
        XCTAssertEqual(script.sends, 2)
    }

    func testARouteThatNeverCameIsNotWaitedForTwice() async {
        let script = Script()
        script.routeComes = false
        script.failures = [Transport()]
        do {
            _ = try await run(script)
            XCTFail("no route must reach the caller")
        } catch {
            XCTAssertTrue(error is Transport)
        }
        XCTAssertEqual(script.waits, 1)
        XCTAssertEqual(script.sends, 1)
    }
}

/// The queue itself: no route, no attempt.
@MainActor
final class QueueWaitsForRouteTests: XCTestCase {
    private var context: NSManagedObjectContext!
    private var chat: Chat!
    private var waits = 0
    private var release: CheckedContinuation<Bool, Never>?

    override func setUp() async throws {
        try await super.setUp()
        let container = PersistenceController(inMemory: true).container
        context = container.viewContext
        LocalRepositories.useMessagesForTesting(container)
        chat = Chat(context: context)
        chat.id = UUID().uuidString
        waits = 0
        MessageRetryManager.shared.useRouteForTesting(
            isRouted: { false },
            waitForRoute: { [weak self] in
                await withCheckedContinuation { continuation in
                    Task { @MainActor in
                        self?.waits += 1
                        self?.release = continuation
                    }
                }
            }
        )
    }

    override func tearDown() async throws {
        release?.resume(returning: false)
        release = nil
        // Let the waiting task finish before the next test swaps the route back.
        await Task.yield()
        MessageRetryManager.shared.useRouteForTesting(isRouted: nil, waitForRoute: nil)
        LocalRepositories.useMessagesForTesting(nil)
        chat = nil
        context = nil
        try await super.tearDown()
    }

    private func stored(_ id: String) -> MessageRecord? {
        try? LocalRepositories.messages.message(id)
    }

    private func queuedMessage(status: DeliveryStatus = .queued, retryCount: Int16 = 1) throws -> String {
        let id = "route-\(UUID().uuidString.lowercased())"
        let message = Message(context: context)
        message.id = id
        message.fromUserId = "me"
        message.toUserId = "peer"
        message.timestamp = Date()
        message.deliveryStatus = status
        message.retryCount = retryCount
        message.isSentByMe = true
        message.contentType = .regular
        message.encryptedContent = Data()
        message.decryptedContent = "hello"
        message.serverOrderKey = ServerMessageOrder.pending(localMessageId: id, composedAt: Date(timeIntervalSince1970: 0))
        message.chat = chat
        try context.save()
        OutgoingWirePayloadStore.shared.saveChunk(
            baseMessageId: id, chunkMessageId: id, wirePayload: Data([0x01]), recipientDeviceId: nil
        )
        addTeardownBlock { OutgoingWirePayloadStore.shared.remove(baseMessageId: id) }
        return id
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    func testTriggersWithoutARouteLeaveTheRowQueuedAndShareOneWait() async throws {
        let id = try queuedMessage()

        var drains: [MessageRetryManager.QueueDrain] = []
        for _ in 0..<4 {
            drains.append(MessageRetryManager.shared.sendQueuedMessages(inChat: chat.id, recipientId: "peer", currentUserId: "me"))
        }
        await settle()

        XCTAssertEqual(drains, Array(repeating: .waitingForRoute, count: 4), "no trigger goes past the route")

        XCTAssertEqual(stored(id)?.deliveryStatus, .queued)
        XCTAssertEqual(stored(id)?.retryCount, 1, "no attempt is spent while there is no route")
        XCTAssertEqual(waits, 1, "four triggers, one wait")
    }

    func testARetryTapWithoutARouteQueuesTheMessageInsteadOfSpendingAnAttempt() async throws {
        let id = try queuedMessage(status: .failed, retryCount: 1)
        guard let row = stored(id).map({ TranscriptRow($0, revision: 0) }) else { return XCTFail("no row") }

        MessageRetryManager.shared.retryMessage(row, recipientId: "peer") { _ in }
        await settle()

        XCTAssertEqual(stored(id)?.deliveryStatus, .queued)
        XCTAssertEqual(stored(id)?.retryCount, 1)
        XCTAssertEqual(waits, 1)
    }
}
