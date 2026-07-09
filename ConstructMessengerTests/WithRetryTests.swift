import XCTest
@testable import Construct_Messenger

/// stealth-sealed-sender-v2 Phase 4: `withRetry` (Utilities/Extensions.swift) now backs
/// `StealthSenderService.getSenderCertificate`'s network fetch, which sits on the hot
/// path for every message once sealed sending is always on. `AuthServiceClient` itself
/// isn't mockable, so these tests cover the generic retry helper directly rather than
/// the specific integration.
final class WithRetryTests: XCTestCase {

    private struct DummyError: Error {}

    func testWithRetry_succeedsOnFirstAttemptWithoutRetrying() async throws {
        var callCount = 0
        let result = try await withRetry(maxAttempts: 3, backoff: 0.01) {
            callCount += 1
            return "ok"
        }
        XCTAssertEqual(result, "ok")
        XCTAssertEqual(callCount, 1)
    }

    func testWithRetry_retriesUntilSuccess() async throws {
        var callCount = 0
        let result = try await withRetry(maxAttempts: 3, backoff: 0.01) {
            callCount += 1
            if callCount < 3 { throw DummyError() }
            return "ok"
        }
        XCTAssertEqual(result, "ok")
        XCTAssertEqual(callCount, 3)
    }

    func testWithRetry_throwsAfterExhaustingAttempts() async {
        var callCount = 0
        do {
            _ = try await withRetry(maxAttempts: 3, backoff: 0.01) {
                callCount += 1
                throw DummyError()
            } as String
            XCTFail("expected withRetry to throw")
        } catch {
            XCTAssertTrue(error is DummyError)
        }
        XCTAssertEqual(callCount, 3)
    }

    func testWithRetry_respectsRetryIfPredicate() async {
        var callCount = 0
        do {
            _ = try await withRetry(maxAttempts: 3, backoff: 0.01, retryIf: { _ in false }) {
                callCount += 1
                throw DummyError()
            } as String
            XCTFail("expected withRetry to throw")
        } catch {
            XCTAssertTrue(error is DummyError)
        }
        // retryIf returns false, so no retry should happen beyond the first attempt.
        XCTAssertEqual(callCount, 1)
    }
}
