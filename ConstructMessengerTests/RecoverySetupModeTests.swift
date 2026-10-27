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

    private func mode(
        held: Bool = false,
        isSetup: Bool = false,
        answered: Bool = true,
        knowsAddress: Bool = true,
        phraseLost: Bool = false
    ) -> AccountRecoveryViewModel.SetupMode {
        AccountRecoveryViewModel.setupMode(
            held: held,
            isSetup: isSetup,
            answered: answered,
            knowsAddress: knowsAddress,
            phraseLost: phraseLost
        )
    }

    /// Mutation: ignore `isSetup` (the defect) — a set-up account is offered a new phrase.
    func testAnAccountWithAKeyIsNotOfferedANewPhrase() {
        XCTAssertEqual(mode(isSetup: true), .alreadySet)
    }

    /// Mutation: `.alreadySet` in place of `.create` — a new account cannot set one up.
    func testAnAccountWithoutAKeyMakesOne() {
        XCTAssertEqual(mode(isSetup: false), .create)
    }

    /// Mutation: check `isSetup` before `held` — the silent key, which is set on the server, could
    /// never be copied.
    func testAHeldPhraseIsShownForCopying() {
        XCTAssertEqual(mode(held: true, isSetup: true), .backupHeld)
        XCTAssertEqual(mode(held: true, isSetup: false, answered: false), .backupHeld)
    }

    /// Mutation: drop `answered` — a status that never loaded reads as "no key" and a new phrase
    /// is offered, which the server refuses if there is one.
    func testAnUnansweredStatusOffersNothing() {
        XCTAssertEqual(mode(isSetup: false, answered: false), .unavailable)
    }

    /// Mutation: drop `knowsAddress` — a device without the account's address is only told the
    /// key exists, and invites stay closed to it.
    func testADeviceWithoutTheAddressEntersThePhrase() {
        XCTAssertEqual(mode(isSetup: true, knowsAddress: false), .confirm)
        // A key cached from an earlier answer is still a key.
        XCTAssertEqual(mode(isSetup: true, answered: false, knowsAddress: false), .confirm)
    }

    /// Mutation: drop `phraseLost` — someone whose phrase is gone is asked to type it.
    func testALostPhraseIsNotAskedFor() {
        XCTAssertEqual(mode(isSetup: true, knowsAddress: false, phraseLost: true), .alreadySet)
    }

    /// Mutation: drop the guard in `startSetup` — the already-set screen can still mint a phrase.
    func testStartSetupMakesNoPhraseOutsideCreate() {
        let vm = AccountRecoveryViewModel()
        for mode: AccountRecoveryViewModel.SetupMode in [.alreadySet, .confirm, .unavailable] {
            vm.setupMode = mode
            vm.startSetup()
            XCTAssertTrue(vm.mnemonic.isEmpty, "\(mode)")
            guard case .idle = vm.setupStep else { return XCTFail("setup step moved in \(mode)") }
        }
    }
}
