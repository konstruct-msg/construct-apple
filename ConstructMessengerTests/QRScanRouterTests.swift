//
//  QRScanRouterTests.swift
//  ConstructMessengerTests
//
//  The routing that silently swallowed every voucher QR.
//

import XCTest
@testable import Construct_Messenger

final class QRScanRouterTests: XCTestCase {

    // MARK: - The regression

    func testAVoucherLinkIsDeliveredVerbatim() {
        // Reported from the field as "Неверный QR-код": the scanner rejected the code
        // before any call site saw it. Verbatim matters — wrapping it as an invite is
        // the other half of the same bug.
        let uri = "konstruct://veil-config?d=eyJjYXBhYmlsaXR5IjoiYWJj"
        XCTAssertEqual(QRScanRouter.route(uri), .deliver(uri))
    }

    func testTheTripleSlashVoucherFormIsAlsoDelivered() {
        // `DeepLinkHandler` tolerates the path form, so the scanner must too.
        let uri = "konstruct:///veil-config?d=eyJjYXBhYmlsaXR5IjoiYWJj"
        XCTAssertEqual(QRScanRouter.route(uri), .deliver(uri))
    }

    func testAVoucherIsNotRewrittenAsAnInvite() {
        let uri = "konstruct://veil-config?d=eyJjYXBhYmlsaXR5IjoiYWJj"
        guard case .deliver(let payload) = QRScanRouter.route(uri) else {
            return XCTFail("must be delivered")
        }
        XCTAssertFalse(payload.contains("invite="))
    }

    // MARK: - What must keep working

    func testDeviceLinkIsStillDelivered() {
        let uri = "konstruct://link?token=abc"
        XCTAssertEqual(QRScanRouter.route(uri), .deliver(uri))
    }

    func testSignedInviteURLIsStillDelivered() {
        let uri = "https://konstruct.cc/add?invite=abc"
        XCTAssertEqual(QRScanRouter.route(uri), .deliver(uri))
    }

    func testABareBase64PayloadIsStillWrappedAsAnInvite() {
        let raw = String(repeating: "A", count: 64)
        XCTAssertEqual(QRScanRouter.route(raw), .deliver("konstruct://add?invite=\(raw)"))
    }

    func testUnrecognisedTextIsInvalid() {
        for text in ["hello world", "https://example.com/", "", "konstruct://unknown"] {
            XCTAssertEqual(QRScanRouter.route(text), .invalid,
                           "must not claim \(text.isEmpty ? "<empty>" : text)")
        }
    }

    func testAVeilConfigLinkWithoutItsBlobIsNotClaimed() {
        // No `d=` means nothing to import; better the generic error than a confusing
        // import failure.
        XCTAssertEqual(QRScanRouter.route("konstruct://veil-config"), .invalid)
    }
}
