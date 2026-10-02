import XCTest
@testable import Construct_Messenger

/// Which invites carry our username (construct-docs TODO 95).
///
/// The QR and a `konstruct://` link carry it, so the person adding us sees who they added — as
/// Android has always shown it. An HTTPS link does not: it passes through other messengers, whose
/// previews and scanners keep it in their logs, and the name would tie it to a person. Mutation:
/// let the HTTPS link through — this reddens.
final class InviteUsernameTests: XCTestCase {

    func testAnHTTPSLinkNeverCarriesTheUsername() {
        XCTAssertNil(InviteGenerator.linkUsername("alice", useHTTPS: true))
    }

    func testAnAppLinkCarriesIt() {
        XCTAssertEqual(InviteGenerator.linkUsername("alice", useHTTPS: false), "alice")
    }
}
