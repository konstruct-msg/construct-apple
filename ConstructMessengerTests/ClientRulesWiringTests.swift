//
//  ClientRulesWiringTests.swift
//  ConstructMessengerTests
//
//  The rules this app takes from the core's construct-rules (decisions/client-rules-shared-in-rust.md):
//  each is tested and mutation-checked in the core; these check the app reaches it. Device refusal
//  and send failure are reached through `LocalDataWipeTests` and `SendFailureTests`.
//

import XCTest
@testable import Construct_Messenger

final class ClientRulesWiringTests: XCTestCase {

    /// The golden vector every client checks: a person is called the same everywhere.
    /// Mutation that reddens it: answer `DisplayNameGenerator.generate` with anything but the core.
    func testTheGeneratedNameIsTheCores() {
        XCTAssertEqual(DisplayNameGenerator.generate(from: "test"), "ancient sphinx")
        XCTAssertTrue(DisplayNameGenerator.isGenerated(" Ancient Sphinx ", for: "test"))
    }

    /// The order and the trimming are the core's: an empty alias is none, a generated shared name
    /// is none, each is trimmed. Mutation that reddens it: the old Swift order, which returned the
    /// shared name untrimmed.
    func testTheShownNameIsTheCores() {
        XCTAssertEqual(ContactName.resolved(alias: "", displayName: " Анна ", username: "anna_k", id: "test"), "Анна")
        XCTAssertEqual(ContactName.resolved(alias: nil, displayName: "Ancient Sphinx", username: "anna_k", id: "test"), "anna_k")
        XCTAssertEqual(ContactName.resolved(alias: nil, displayName: "", username: "", id: "test"), "ancient sphinx")
    }
}
