//
//  RecoveryErrorMessageTests.swift
//  ConstructMessengerTests
//
//  A recovery refusal reads as what the server refused. The mapping searched
//  `localizedDescription` for status names, which a grpc-swift 2 `RPCError` never contains, so
//  every refusal showed "The operation couldn't be completed (GRPCCore.RPCError error 1)"
//  (device, 2026-09-30: recovery phrase setup failed after the quiz with nothing else to go on).
//

import GRPCCore
import XCTest
@testable import Construct_Messenger

@MainActor
final class RecoveryErrorMessageTests: XCTestCase {

    /// Mutation: map by `localizedDescription` again — this reddens.
    func testAKeyAlreadySetReadsAsThat() {
        let error = RPCError(code: .alreadyExists, message: "Recovery key already set and cannot be changed")
        XCTAssertEqual(
            AccountRecoveryViewModel.errorMessage(from: error),
            NSLocalizedString("recovery_error_already_set", comment: "")
        )
    }

    func testEveryMappedCodeHasItsOwnText() {
        let mapped: [RPCError.Code: String] = [
            .notFound: "recovery_error_not_found",
            .failedPrecondition: "recovery_error_not_configured",
            .permissionDenied: "recovery_error_wrong_phrase",
            .resourceExhausted: "recovery_error_cooldown",
            .alreadyExists: "recovery_error_already_set"
        ]
        for (code, key) in mapped {
            XCTAssertEqual(
                AccountRecoveryViewModel.errorMessage(from: RPCError(code: code, message: "x")),
                NSLocalizedString(key, comment: ""),
                "\(code)"
            )
        }
    }

    /// Anything else is our general sentence for a server refusal, never the server's own words
    /// (TODO 128) — they are English, and written for whoever reads the server's logs.
    func testAnUnmappedRefusalSaysOurSentenceNotTheServers() {
        let error = RPCError(code: .invalidArgument, message: "Setup signature has expired")
        XCTAssertEqual(AccountRecoveryViewModel.errorMessage(from: error), UserText("error_server").resolved)
    }
}
