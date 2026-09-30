//
//  SealedChannelFailureTests.swift
//  ConstructMessengerTests
//
//  The sealed channel carries sends and, since 2026-09-30, media downloads. A status the server
//  answered — NOT_FOUND for expired media above all — must not replace the connection sends are
//  using; a transport failure still does.
//

import XCTest
import GRPCCore
@testable import Construct_Messenger

final class SealedChannelFailureTests: XCTestCase {

    func testServerAnswersKeepTheConnection() {
        for code in [RPCError.Code.notFound, .invalidArgument, .resourceExhausted, .permissionDenied, .unauthenticated] {
            XCTAssertTrue(
                GRPCChannelManager.sealedFailureKeepsConnection(RPCError(code: code, message: "")),
                "\(code) was answered by the server; the connection worked"
            )
        }
    }

    func testTransportFailuresReplaceTheConnection() {
        XCTAssertFalse(GRPCChannelManager.sealedFailureKeepsConnection(
            RPCError(code: .unavailable, message: "Write failed.")))
        XCTAssertFalse(GRPCChannelManager.sealedFailureKeepsConnection(POSIXError(.ECONNRESET)))
    }
}
