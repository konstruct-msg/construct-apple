//
//  DeviceJoinTests.swift
//  ConstructMessengerTests
//

import GRPCCore
import XCTest
@testable import Construct_Messenger

/// The calls and the clock reach the core's wait, and its end reaches the person. The rule itself
/// is tested in construct-rules (`device_join`).
@MainActor
final class DeviceJoinTests: XCTestCase {

    private var now: Int64 = 0
    private var asked = 0
    private var signedIn = 0

    /// Each list is answered in turn, its last answer repeated; sleeping moves the clock.
    private func run(
        _ statuses: [Result<Int32, any Error>],
        _ signIns: [Result<Void, any Error>]
    ) async throws -> DeviceJoin.Outcome {
        try await DeviceJoin(
            status: {
                defer { self.asked += 1 }
                return try statuses[min(self.asked, statuses.count - 1)].get()
            },
            signIn: {
                defer { self.signedIn += 1 }
                try signIns[min(self.signedIn, signIns.count - 1)].get()
                return .init(userId: "u", accessToken: "a", refreshToken: "r", expiresAt: 1, veilBridgeCert: nil)
            },
            nowMs: { self.now },
            sleep: { self.now += $0 }
        ).run()
    }

    private func rpc(_ code: RPCError.Code) -> any Error { RPCError(code: code, message: "in a test") }

    private func end(_ outcome: DeviceJoin.Outcome) -> DeviceJoinEnd? {
        if case .ended(let end) = outcome { return end }
        return nil
    }

    func testItAsksAndSignsInOnceLetIn() async throws {
        let outcome = try await run([.success(0), .failure(rpc(.unavailable)), .success(1)], [.success(())])
        guard case .signedIn(let result) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(result.accessToken, "a")
        XCTAssertEqual([asked, signedIn], [3, 1])
        XCTAssertEqual(now, 9_000)
    }

    /// The error of a sign-in reaches the rule as what it was: no answer is tried again, a refusal
    /// ends the join.
    func testASignInIsTriedAgainUnlessRefused() async throws {
        let refused = try await run(
            [.success(1)],
            [.failure(GRPCClientError.clientSideTimeout), .failure(rpc(.unavailable)), .failure(rpc(.unauthenticated))]
        )
        XCTAssertEqual(end(refused), .signInRefused)
        XCTAssertEqual([asked, signedIn], [1, 3])
    }

    func testTheStatusReachesTheRule() async throws {
        let rejected = try await run([.success(2)], [.success(())])
        XCTAssertEqual(end(rejected), .rejected)
        XCTAssertEqual(signedIn, 0)
        let expired = try await run([.success(3)], [.failure(rpc(.unauthenticated))])
        XCTAssertEqual(end(expired), .expired)
    }

    /// The clock reaches the rule: nobody answers, and the wait ends by itself.
    func testItEndsWithoutAnAnswer() async throws {
        let outcome = try await run([.success(1)], [.failure(rpc(.unavailable))])
        XCTAssertEqual(end(outcome), .letInUnreachable)
        XCTAssertGreaterThan(now, 600_000)
    }

    func testACancelledWaitEnds() async {
        let task = Task { try await run([.success(0)], [.success(())]) }
        task.cancel()
        let result = await task.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
    }

    func testEachEndIsItsOwnSentence() {
        let ends: [DeviceJoinEnd] = [.rejected, .expired, .signInRefused, .letInUnreachable]
        XCTAssertEqual(Set(ends.map { DeviceLinkError($0).userText.resolved }).count, ends.count)
        XCTAssertEqual(DeviceLinkError(.expired).userText.resolved, DeviceLinkError.expired.userText.resolved)
        XCTAssertEqual(DeviceLinkError(.signInRefused).userText.resolved, DeviceLinkError.signInRefused.userText.resolved)
        XCTAssertEqual(DeviceLinkError(.rejected).userText.resolved, DeviceLinkError.rejected.userText.resolved)
    }
}
