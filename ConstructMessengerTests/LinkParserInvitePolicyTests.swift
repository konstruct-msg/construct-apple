//
//  LinkParserInvitePolicyTests.swift
//  ConstructMessengerTests
//
//  F4: legacy unsigned /c/ links must be rejected (no downgrade path).
//

import XCTest
@testable import Construct_Messenger

final class LinkParserInvitePolicyTests: XCTestCase {

    func testLegacyContactPathRejected() async {
        let url = URL(string: "https://konstruct.cc/c/14f28d31-1234-4abc-8def-0123456789ab?username=alice")!
        do {
            _ = try await LinkParser.parseContactLink(url)
            XCTFail("legacy /c/ link must not be accepted")
        } catch let error as ContactLinkError {
            switch error {
            case .inviteInvalid:
                break // expected
            default:
                XCTFail("expected inviteInvalid, got \(error)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testUnsupportedPrefixRejected() async {
        let url = URL(string: "https://example.com/foo")!
        do {
            _ = try await LinkParser.parseContactLink(url)
            XCTFail("unsupported host must not be accepted")
        } catch let error as ContactLinkError {
            if case .invalidPrefix = error {
                // expected
            } else {
                XCTFail("expected invalidPrefix, got \(error)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
}
