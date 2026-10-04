//
//  RecoveryKeyProvisionerTests.swift
//  ConstructMessengerTests
//
//  The silent recovery key (`decisions/recovery-key-backup-is-deferred-not-skipped.md`). What is
//  pinned is the order: the phrase is stored before the server hears of the key, a retry reuses
//  it, and it moves behind authentication only once the server took it. Each test names the
//  mutation that reddens it.
//

import XCTest
@testable import Construct_Messenger

private final class FakeStore: RecoveryPhraseStore {
    var canHold = true
    var pending: (phrase: String, account: String)?
    var held: (phrase: String, account: String)?
    var failStore = false
    var failPromote = false
    /// What was stored at the moment the upload ran — the order check.
    var pendingAtUpload: String?

    func storePending(_ phrase: String, account: String) -> Bool {
        guard !failStore else { return false }
        pending = (phrase, account)
        return true
    }
    func pendingPhrase(account: String) -> String? {
        pending?.account == account ? pending?.phrase : nil
    }
    func promotePending(account: String) -> Bool {
        guard !failPromote, let p = pending, p.account == account else { return false }
        held = p
        pending = nil
        return true
    }
    func hasHeld(account: String) -> Bool { held?.account == account }
    func readHeld(account: String, reason: String) async -> String? {
        held?.account == account ? held?.phrase : nil
    }
    func forgetPending() { pending = nil }
    func forgetHeld() { held = nil }
}

private struct OtherKey: Error {}
private struct Offline: Error {}

@MainActor
final class RecoveryKeyProvisionerTests: XCTestCase {

    private var store = FakeStore()
    private var address: Data?
    private var serverHasKey = false
    private var statusFails = false
    private var uploadResult: Result<Data, Error> = .success(Data(repeating: 7, count: 32))
    private var uploads: [String] = []
    private var generated = 0

    private func expectOutcome(
        _ expected: RecoveryKeyProvisioner.Outcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let outcome = await provisioner().ensureKey(userId: "u1")
        XCTAssertEqual(outcome, expected, file: file, line: line)
    }

    private func provisioner() -> RecoveryKeyProvisioner {
        RecoveryKeyProvisioner(dependencies: .init(
            knownAddress: { [unowned self] in address },
            serverHasKey: { [unowned self] in
                if statusFails { throw Offline() }
                return serverHasKey
            },
            generatePhrase: { [unowned self] in
                generated += 1
                return "phrase-\(generated)"
            },
            upload: { [unowned self] phrase, _ in
                store.pendingAtUpload = store.pendingPhrase(account: "u1")
                uploads.append(phrase)
                return try uploadResult.get()
            },
            isOtherKeySet: { $0 is OtherKey },
            rememberAddress: { [unowned self] in address = $0 },
            store: store
        ))
    }

    /// Mutation: upload before `storePending` — the phrase is not in the vault when the server
    /// takes its key, and this reddens.
    func testThePhraseIsStoredBeforeTheServerHearsOfTheKey() async {
        let outcome = await provisioner().ensureKey(userId: "u1")
        XCTAssertEqual(outcome, .provisioned)
        XCTAssertEqual(store.pendingAtUpload, "phrase-1")
        XCTAssertEqual(store.held?.phrase, "phrase-1", "moved behind authentication once set")
        XCTAssertNil(store.pending)
        XCTAssertEqual(address, Data(repeating: 7, count: 32))
    }

    /// Mutation: generate a fresh phrase on every run — the retry sets a second key whose first
    /// phrase is gone, and this reddens.
    func testARetryReusesThePendingPhrase() async {
        uploadResult = .failure(Offline())
        await expectOutcome(.deferred)
        XCTAssertEqual(store.pending?.phrase, "phrase-1", "kept for the next attempt")

        uploadResult = .success(Data(repeating: 7, count: 32))
        await expectOutcome(.provisioned)
        XCTAssertEqual(uploads, ["phrase-1", "phrase-1"])
        XCTAssertEqual(generated, 1)
    }

    /// Another key on the server means this phrase names nothing; keeping it would offer the
    /// person a "copy" of a key that recovers nothing.
    func testAnotherKeyOnTheServerDropsThePendingPhrase() async {
        uploadResult = .failure(OtherKey())
        await expectOutcome(.setElsewhere)
        XCTAssertNil(store.pending)
        XCTAssertNil(store.held)
        XCTAssertNil(address)
    }

    func testAKnownAddressDoesNothing() async {
        address = Data(repeating: 1, count: 32)
        await expectOutcome(.alreadyKnown)
        XCTAssertEqual(generated, 0)
        XCTAssertTrue(uploads.isEmpty)
    }

    /// A key set on another device is not replaced, and no phrase is made for it.
    func testAKeySetElsewhereIsLeftAlone() async {
        serverHasKey = true
        await expectOutcome(.setElsewhere)
        XCTAssertEqual(generated, 0)
    }

    /// Nothing is generated while the server cannot say whether a key exists: a phrase made then
    /// could lose to the account's real key.
    func testNoPhraseIsMadeWhileTheStatusIsUnknown() async {
        statusFails = true
        await expectOutcome(.deferred)
        XCTAssertEqual(generated, 0)
    }

    /// No passcode: nothing can wait safely, so the visible setup runs (owner's decision).
    ///
    /// Mutation: ignore `canHold` — a phrase is generated with nowhere safe to wait.
    func testWithoutAPasscodeTheVisibleSetupRuns() async {
        store.canHold = false
        await expectOutcome(.needsVisibleSetup)
        XCTAssertEqual(generated, 0)
        XCTAssertTrue(uploads.isEmpty)
    }

    func testAPhraseThatCannotBeStoredIsNeverUploaded() async {
        store.failStore = true
        await expectOutcome(.needsVisibleSetup)
        XCTAssertTrue(uploads.isEmpty)
    }

    /// Set but not moved behind authentication: the phrase stays pending — readable, not lost.
    func testAFailedPromotionKeepsThePhrasePending() async {
        store.failPromote = true
        await expectOutcome(.provisioned)
        XCTAssertEqual(store.pending?.phrase, "phrase-1")
    }

    /// Another account's pending phrase is not this one's.
    func testAPendingPhraseBelongsToItsAccount() async {
        store.pending = ("someone-else", "u2")
        await expectOutcome(.provisioned)
        XCTAssertEqual(uploads, ["phrase-1"])
    }

    // MARK: - The word check

    func testTheOptionsHoldTheAnswerAndOnlyWordsFromThePhrase() {
        let phrase = (1...12).map { "w\($0)" }
        var generator = SystemRandomNumberGenerator()
        for index in phrase.indices {
            let options = AccountRecoveryViewModel.quizOptions(for: phrase, index: index, using: &generator)
            XCTAssertEqual(options.count, 4)
            XCTAssertEqual(Set(options).count, 4, "no word offered twice")
            XCTAssertTrue(options.contains(phrase[index]))
            XCTAssertTrue(Set(options).isSubset(of: Set(phrase)))
        }
    }

    /// A phrase may repeat a word; the answer must still be offered once and the decoys differ.
    func testARepeatedWordIsNotOfferedAsItsOwnDecoy() {
        let phrase = ["same", "same", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j"]
        var generator = SystemRandomNumberGenerator()
        let options = AccountRecoveryViewModel.quizOptions(for: phrase, index: 0, using: &generator)
        XCTAssertEqual(options.filter { $0 == "same" }.count, 1)
        XCTAssertEqual(options.count, 4)
    }
}
