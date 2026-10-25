import XCTest
import Synchronization
@testable import Construct_Messenger

/// `CryptoManager` is `@unchecked Sendable` on the claim that its stored state is read and written
/// only under `coreLock`. Until 2026-10-25 about fifty sites read it without the lock, from callers
/// off the main actor. Each test holds the lock on this thread and checks that an access from
/// another thread waits for it.
final class CryptoManagerLockTests: XCTestCase {

    private func assertWaitsForCoreLock(_ name: String, _ access: @escaping @Sendable () -> Void) {
        let crypto = CryptoManager.shared
        let finished = Mutex(false)
        let done = expectation(description: name)

        crypto.coreLock.lock()
        DispatchQueue.global().async {
            access()
            finished.withLock { $0 = true }
            done.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertFalse(finished.withLock { $0 }, "\(name) ran while another thread held coreLock")
        crypto.coreLock.unlock()
        wait(for: [done], timeout: 5)
    }

    func testReadingTheCoreWaitsForTheLock() {
        assertWaitsForCoreLock("orchestratorCore") { _ = CryptoManager.shared.orchestratorCore }
    }

    func testTheOtpkReplacementFlagWaitsForTheLock() {
        assertWaitsForCoreLock("needsFullOtpkReplacement") { _ = CryptoManager.shared.needsFullOtpkReplacement }
    }

    func testTheCachedAccountWaitsForTheLock() {
        assertWaitsForCoreLock("_cachedUserId") { _ = CryptoManager.shared._cachedUserId }
    }
}
