//
//  RecoverySetupModeTests.swift
//  ConstructMessengerTests
//
//  Which flow the recovery setup screen opens on (`AccountRecoveryViewModel.setupMode`). Until
//  2026-10-27 it read only whether a phrase was held on the device: an account whose key was set
//  and copied got a fresh phrase, a quiz, and then the server's refusal — the key cannot change.
//  Each test names the mutation that reddens it.
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class RecoverySetupModeTests: XCTestCase {

    /// Mutation: ignore `isSetup` (the defect) — a set-up account is offered a new phrase.
    func testAnAccountWithAKeyIsNotOfferedANewPhrase() {
        XCTAssertEqual(AccountRecoveryViewModel.setupMode(held: false, isSetup: true), .alreadySet)
    }

    /// Mutation: always `.alreadySet` without a held phrase — a new account cannot set one up.
    func testAnAccountWithoutAKeyMakesOne() {
        XCTAssertEqual(AccountRecoveryViewModel.setupMode(held: false, isSetup: false), .create)
    }

    /// Mutation: check `isSetup` before `held` — the silent key, which is set on the server, could
    /// never be copied.
    func testAHeldPhraseIsShownForCopying() {
        XCTAssertEqual(AccountRecoveryViewModel.setupMode(held: true, isSetup: true), .backupHeld)
        XCTAssertEqual(AccountRecoveryViewModel.setupMode(held: true, isSetup: false), .backupHeld)
    }

    /// Mutation: drop the guard in `startSetup` — the already-set screen can still mint a phrase.
    func testStartSetupMakesNoPhraseOutsideCreate() {
        let vm = AccountRecoveryViewModel()
        vm.setupMode = .alreadySet
        vm.startSetup()
        XCTAssertTrue(vm.mnemonic.isEmpty)
        guard case .idle = vm.setupStep else { return XCTFail("setup step moved: \(vm.setupStep)") }
    }
}
