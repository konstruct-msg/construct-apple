import GRPCCore
import XCTest
@testable import Construct_Messenger

/// Recovery runs on a device with no session, by definition. The interceptor refuses any RPC it does
/// not list, before the network, so a missing entry looks like an expired token and reaches no server.
final class RecoveryNeedsNoSessionTests: XCTestCase {
    func testRecoverAccountIsNotRefusedForWantOfASession() {
        XCTAssertEqual(
            Shared_Proto_Services_V1_AuthService.Method.RecoverAccount.descriptor.method,
            "RecoverAccount"
        )
        XCTAssertTrue(AuthInterceptor.isUnauthenticated(method: "RecoverAccount"))
    }
}
