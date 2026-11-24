//
//  JoinApprovalTests.swift
//  ConstructMessengerTests
//

import GRPCCore
import XCTest
@testable import Construct_Messenger

/// A device let in by the phone takes its tokens by signing in with its own key
/// (`decisions/a-joining-device-signs-in-with-its-own-key.md`).
@MainActor
final class JoinApprovalTests: XCTestCase {

    private var asked = 0
    private var signedIn = 0

    /// Each list is answered in turn, its last answer repeated.
    private func join(
        _ statuses: [Result<Bool, any Error>],
        _ signIns: [Result<Void, any Error>]
    ) -> JoinApproval {
        JoinApproval(
            isApproved: {
                defer { self.asked += 1 }
                return try statuses[min(self.asked, statuses.count - 1)].get()
            },
            signIn: {
                defer { self.signedIn += 1 }
                try signIns[min(self.signedIn, signIns.count - 1)].get()
                return .init(userId: "u", accessToken: "a", refreshToken: "r", expiresAt: 1, veilBridgeCert: nil)
            }
        )
    }

    private func rpc(_ code: RPCError.Code) -> any Error { RPCError(code: code, message: "in a test") }

    private func thrown(by join: JoinApproval) async -> (any Error)? {
        do { _ = try await join.poll(); return nil } catch { return error }
    }

    func testItSignsInOnlyAfterTheApproval() async throws {
        let join = join([.success(false), .success(true)], [.success(())])
        let first = try await join.poll()
        XCTAssertNil(first)
        XCTAssertEqual(signedIn, 0)
        let second = try await join.poll()
        XCTAssertEqual(second?.accessToken, "a")
        XCTAssertEqual(signedIn, 1)
    }

    /// The server forgets an approval after two minutes.
    func testASignInThatDidNotGetThroughIsTriedAgainWithoutAsking() async throws {
        let join = join(
            [.success(true), .failure(DeviceLinkError.expired)],
            [.failure(rpc(.unavailable)), .failure(rpc(.deadlineExceeded)), .success(())]
        )
        for code in [RPCError.Code.unavailable, .deadlineExceeded] {
            let error = await thrown(by: join)
            XCTAssertEqual((error as? RPCError)?.code, code)
        }
        let result = try await join.poll()
        XCTAssertNotNil(result)
        XCTAssertEqual(asked, 1)
    }

    func testARefusedSignInEndsTheJoin() async {
        for code in [RPCError.Code.invalidArgument, .unauthenticated, .permissionDenied] {
            signedIn = 0
            let error = await thrown(by: join([.success(true)], [.failure(rpc(code))]))
            let refused = error as? JoinApproval.SignInRefused
            XCTAssertEqual((refused?.underlying as? RPCError)?.code, code)
        }
    }

    /// The same codes from the status are not a refused sign-in: nothing was approved.
    func testAnErrorOfTheStatusIsItsOwn() async {
        for error in [DeviceLinkError.rejected, .expired] {
            let got = await thrown(by: join([.failure(error)], [.success(())]))
            XCTAssertEqual((got as? DeviceLinkError)?.errorDescription, error.errorDescription)
        }
        let got = await thrown(by: join([.failure(rpc(.unauthenticated))], [.success(())]))
        XCTAssertEqual((got as? RPCError)?.code, .unauthenticated)
        XCTAssertEqual(signedIn, 0)
    }
}
