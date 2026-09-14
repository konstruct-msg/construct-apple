//
//  ResponderDeviceWalkTests.swift
//  ConstructMessengerTests
//
//  Which of the sender's devices produced a handshake is not on the wire, so the responder has to
//  ask each of them. Devices 2026-08-28: all ten bundle fetches went out with `deviceId=nil`, and
//  a single-device contact could not establish a session with a two-device account at all.
//
//  Acceptance is mutation-based; each test names the mutation that must redden it.
//

import XCTest
import CryptoKit
@testable import Construct_Messenger

final class ResponderDeviceWalkTests: XCTestCase {

    private let account = "ffeeddc6-14f2-4d02-a66a-caf0d8dfeda8"

    private func bundle(device: String) -> DeviceBundleData {
        DeviceBundleData(
            deviceId: device,
            bundle: PublicKeyBundleData(
                userId: account,
                username: "",
                identityPublic: Data(repeating: 1, count: 32),
                signedPrekeyPublic: Data(repeating: 2, count: 32),
                signature: Data(repeating: 3, count: 64),
                verifyingKey: Data(repeating: 4, count: 32),
                suiteId: 1,
                spkUploadedAt: 0,
                spkRotationEpoch: 0,
                kyberSpkUploadedAt: 0,
                kyberSpkRotationEpoch: 0
            ),
            platform: .unspecified
        )
    }

    private func ids(_ bundles: [DeviceBundleData]) -> [String] { bundles.map(\.deviceId) }

    // MARK: - Order

    /// The pinned device goes first, so a single-device account — nearly all of them — ends the
    /// walk on its first attempt, exactly as the single fetch did.
    ///
    /// Mutation: return the server's order unchanged — this reddens.
    func testThePinnedDeviceIsTriedFirst() {
        let bundles = [bundle(device: "aaaa1111"), bundle(device: "bbbb2222"), bundle(device: "cccc3333")]
        let ordered = PublicKeyBundleHandler.orderedByLikelihood(bundles, pinnedDeviceId: "cccc3333")
        XCTAssertEqual(ids(ordered).first, "cccc3333")
    }

    /// Everything else keeps the order the server gave. `sorted(by:)` is not stable, and shuffling
    /// the devices we are not confident about would make the walk differ between runs for nothing.
    ///
    /// Mutation: implement the move as a `sorted` on a 0/1 key — this reddens on the tail order
    /// whenever the sort is not stable.
    func testTheRestKeepTheServersOrder() {
        let bundles = [bundle(device: "aaaa1111"), bundle(device: "bbbb2222"),
                       bundle(device: "cccc3333"), bundle(device: "dddd4444")]
        let ordered = PublicKeyBundleHandler.orderedByLikelihood(bundles, pinnedDeviceId: "cccc3333")
        XCTAssertEqual(ids(ordered), ["cccc3333", "aaaa1111", "bbbb2222", "dddd4444"])
    }

    /// Nothing is dropped and nothing is duplicated — the walk must be able to reach every device
    /// the account has, which is the entire point.
    ///
    /// Mutation: `insert` without the matching `remove` — this reddens on the count.
    func testEveryDeviceSurvivesTheReordering() {
        let bundles = (1...5).map { bundle(device: "dev\($0)") }
        for pinned in ["dev1", "dev3", "dev5", "nosuchdevice"] {
            let ordered = PublicKeyBundleHandler.orderedByLikelihood(bundles, pinnedDeviceId: pinned)
            XCTAssertEqual(ordered.count, bundles.count, "pinned=\(pinned)")
            XCTAssertEqual(Set(ids(ordered)), Set(ids(bundles)), "pinned=\(pinned)")
        }
    }

    /// An unpinned contact — one we have never verified — still gets a full walk in the server's
    /// order. This is the first-contact case, which is exactly when there is no pin to prefer.
    ///
    /// Mutation: return an empty list when there is no pin — this reddens, and on a device it
    /// would mean no session could ever be established with a new contact.
    func testAnUnpinnedContactStillGetsEveryDevice() {
        let bundles = [bundle(device: "aaaa1111"), bundle(device: "bbbb2222")]
        for pinned in [nil, "", "notoneofthem"] as [String?] {
            let ordered = PublicKeyBundleHandler.orderedByLikelihood(bundles, pinnedDeviceId: pinned)
            XCTAssertEqual(ids(ordered), ["aaaa1111", "bbbb2222"])
        }
    }

    /// A server that returns nothing yields nothing — not a crash on `firstIndex` of an empty list.
    func testNoDevicesIsNoCandidates() {
        XCTAssertTrue(PublicKeyBundleHandler.orderedByLikelihood([], pinnedDeviceId: "aaaa1111").isEmpty)
    }

    // MARK: - The walk itself

    /// The responder must not burn one of the sender's one-time pre-keys. A RESPONDER init uses
    /// the sender's identity, SPK and verifying key plus *our own* private OTPK, named by the
    /// message — the sender's is never touched. The old fetch consumed one per attempt and per
    /// retry, draining the pool of every peer that messaged us first.
    ///
    /// Mutation: fetch with `consumeOneTimePrekey: true` — this reddens.
    func testTheWalkDoesNotConsumeThePeersOneTimePreKeys() throws {
        let source = try sourceOf("ConstructMessenger/Services/Messaging/PublicKeyBundleHandler.swift")
        let walk = try XCTUnwrap(source.range(of: "func responderBundleCandidates"))
        let body = String(source[walk.lowerBound...].prefix(600))
        XCTAssertTrue(
            body.contains("consumeOneTimePrekey: false"),
            "a responder init needs no OTPK from the sender, and there are now several fetches"
        )
    }

    /// Both responder paths walk the candidates: the first message and the heal that retries it.
    /// A heal that asks for one bundle asks about one device and fails exactly as the init did.
    ///
    /// Mutation: revert either call site to `fetchPublicKeyWithRetry` — this reddens.
    func testBothResponderPathsWalkTheDevices() throws {
        let source = try sourceOf("ConstructMessenger/Services/Session/SessionCoordinator.swift")
        let occurrences = source.components(separatedBy: "responderBundleCandidates(userId:").count - 1
        XCTAssertEqual(
            occurrences, 2,
            "the first-message path and the heal path both open a message whose sending device the "
            + "delivery does not name"
        )
    }

    /// The repair paths a failed init triggers are for a genuine key desync. With devices left to
    /// try, a failure means only "not this one", and firing them per candidate would call
    /// `verifyAndRepairKeyConsistency` once per device of every account that messages us.
    ///
    /// Mutation: drop the `isLastCandidate` guard — this reddens.
    func testTheRepairPathsFireOnlyOnTheLastCandidate() throws {
        let source = try sourceOf("ConstructMessenger/Services/Messaging/PublicKeyBundleHandler.swift")
        let guarded = source.components(separatedBy: "if isLastCandidate {").count - 1
        XCTAssertEqual(guarded, 2, "both failure branches must gate the repair")
        XCTAssertTrue(
            source.contains("isLastCandidate: Bool = true"),
            "the default keeps every existing caller reporting failures as before"
        )
    }

    private func sourceOf(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try XCTUnwrap(try? String(contentsOf: url, encoding: .utf8))
    }
}
