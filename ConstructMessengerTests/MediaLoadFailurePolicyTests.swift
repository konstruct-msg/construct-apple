//
//  MediaLoadFailurePolicyTests.swift
//  ConstructMessengerTests
//
//  Retrying a descriptor the media service has already answered notFound for only repeats the
//  same request. Transient transport failures keep Retry; a missing object does not.
//

import XCTest
import GRPCCore
@testable import Construct_Messenger

final class MediaLoadFailurePolicyTests: XCTestCase {

    func testNotFoundIsPermanentlyUnavailable() {
        XCTAssertEqual(
            MediaLoadFailurePolicy.disposition(forRPCCode: .notFound),
            .permanentlyUnavailable
        )
    }

    func testTransportFailuresRemainRetryable() {
        XCTAssertEqual(MediaLoadFailurePolicy.disposition(forRPCCode: .unavailable), .retryable)
        XCTAssertEqual(MediaLoadFailurePolicy.disposition(forRPCCode: .deadlineExceeded), .retryable)
        XCTAssertEqual(MediaLoadFailurePolicy.disposition(forRPCCode: .cancelled), .retryable)
        XCTAssertEqual(MediaLoadFailurePolicy.disposition(forRPCCode: nil), .retryable)
    }

    func testErrorOverloadReadsRPCCode() {
        let error = RPCError(code: .notFound, message: "gone")
        XCTAssertEqual(MediaLoadFailurePolicy.disposition(for: error), .permanentlyUnavailable)
    }
}
