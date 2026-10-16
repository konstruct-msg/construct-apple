import XCTest
@testable import Construct_Messenger

/// A refresh that fails never signs out (2026-10-16). On 2026-10-15 the timer's own refresh raced
/// the foreground restore's coordinator refresh on one refresh token; the loser's rejection ran
/// `handleSessionExpired`, which wiped the session and the stream cursor, and the stream replayed
/// the whole backlog for an identity that was back a second later.
final class TokenRefreshOutcomeTests: XCTestCase {

    /// Mutation: map `.transient` or `.refused` to a sign-out / session wipe — this reddens.
    func testNoRefreshResultSignsOut() {
        XCTAssertEqual(TokenRefreshOutcome.refreshed.action, .reschedule)
        XCTAssertEqual(TokenRefreshOutcome.transient.action, .retry(after: TokenRefreshOutcome.transientRetryDelay))
        XCTAssertEqual(TokenRefreshOutcome.refused.action, .reauthenticateDevice)
    }

    /// Single flight: every refresh goes through `TokenRefreshCoordinator`. A second caller of
    /// `AuthServiceClient.refreshToken` is what raced it.
    /// Mutation: call `AuthServiceClient.shared.refreshToken(` from `AuthViewModel` — this reddens.
    func testOnlyTheCoordinatorCallsTheRefreshRPC() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        var callers: [String] = []
        for dir in ["ConstructMessenger", "Construct Desktop"] {
            guard let walker = FileManager.default.enumerator(at: root.appendingPathComponent(dir), includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                for (n, line) in text.components(separatedBy: "\n").enumerated()
                where line.contains("AuthServiceClient.shared.refreshToken(") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                    callers.append("\(url.lastPathComponent):\(n + 1)")
                }
            }
        }
        XCTAssertEqual(callers.count, 1, "refresh RPC callers: \(callers)")
        XCTAssertTrue(callers.first?.hasPrefix("TokenRefreshCoordinator.swift:") == true, "\(callers)")
    }
}
