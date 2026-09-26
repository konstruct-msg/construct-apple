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

    /// The device the carrier's certificate named goes before the pinned one: the pin says whom
    /// we talked to before, the certificate says who wrote this. On the stand a re-init from the
    /// sibling walked the pinned device first and archived its healthy session on the way.
    ///
    /// Mutation: apply the named move before the pinned one — this reddens on the first element.
    func testTheNamedDeviceGoesBeforeThePinnedOne() {
        let bundles = [bundle(device: "aaaa1111"), bundle(device: "bbbb2222"), bundle(device: "cccc3333")]
        let ordered = PublicKeyBundleHandler.orderedByLikelihood(
            bundles, pinnedDeviceId: "cccc3333", namedDeviceId: "bbbb2222"
        )
        XCTAssertEqual(ids(ordered), ["bbbb2222", "cccc3333", "aaaa1111"])
    }

    /// A name that matches no bundle — an unvouched certificate, or a device since revoked —
    /// changes nothing; the pin still leads.
    func testAnUnknownNamedDeviceLeavesThePinFirst() {
        let bundles = [bundle(device: "aaaa1111"), bundle(device: "cccc3333")]
        for named in [nil, "", "notoneofthem"] as [String?] {
            let ordered = PublicKeyBundleHandler.orderedByLikelihood(
                bundles, pinnedDeviceId: "cccc3333", namedDeviceId: named
            )
            XCTAssertEqual(ids(ordered), ["cccc3333", "aaaa1111"], "named=\(named ?? "nil")")
        }
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

    /// Both responder paths open through one call, and the core makes the walk. Until 2026-09-26
    /// the walk was this app's (`walkReceivingPlan` over `PendingSessionQueue`), and before C10 the
    /// heal kept a second copy of it that had already diverged — one carrier held fixed while the
    /// bundles rotated by hand.
    ///
    /// Mutation: give either path its own bundle fetch or its own init call — this reddens.
    func testBothResponderPathsOpenThroughTheCore() throws {
        let source = try sourceOf("ConstructMessenger/Services/Session/SessionCoordinator.swift")
        func count(_ needle: String) -> Int { source.components(separatedBy: needle).count - 1 }
        XCTAssertEqual(count("responderBundleCandidates("), 1, "one bundle fetch, in the one open")
        XCTAssertEqual(count("CryptoManager.shared.openReceiving("), 1, "one call into the core's walk")
        XCTAssertEqual(count("await openReceiving("), 2, "the first message and the heal both use it")
        XCTAssertEqual(count("namedDevice: claimed"), 1, "the claimed device goes first in the fetch")
        for gone in ["planReceivingInit(", "initReceivingSession(", "in candidates.enumerated()"] {
            XCTAssertFalse(source.contains(gone), "\(gone) is a walk of this app's beside the core's")
        }
    }

    /// A SESSION_RESET_INIT the core opened a session from is saved through the router's decrypt
    /// path (`resolveCoreDrain` → `executeRustActions`), which the live route never lets it reach.
    /// Its type is the unsealed content type, not a plaintext frame, so nothing there recognised
    /// it: stand run 2026-09-26, a "$<uuid>" bubble on both sides after a reset.
    ///
    /// Mutation: drop the `isSessionResetInit` check from the decrypt branch — this reddens.
    func testAnOpenedResetInitNeverReachesTheTranscript() throws {
        let source = try sourceOf("ConstructMessenger/Services/Messaging/MessageRouter.swift")
        let body = try XCTUnwrap(source.range(of: "private func executeRustActions("))
        let tail = source[body.lowerBound...]
        let check = try XCTUnwrap(tail.range(of: "if message.isSessionResetInit {"))
        let framed = try XCTUnwrap(tail.range(of: "if handleFramedSideChannel("))
        XCTAssertLessThan(check.lowerBound, framed.lowerBound, "recognised before anything that saves a row")
    }

    /// The key-repair path is for our own keys being out of step with the server, which only an
    /// open that failed against every bundle of the account can suggest. Fired per attempt it would
    /// call `verifyAndRepairKeyConsistency` once per device of every account that messages us.
    ///
    /// Mutation: run the repair unconditionally on a failed open — this reddens.
    func testTheRepairPathFiresOnlyWhenEveryBundleRefused() throws {
        let source = try sourceOf("ConstructMessenger/Services/Session/SessionCoordinator.swift")
        let open = try XCTUnwrap(source.range(of: "private func openReceiving("))
        let body = String(source[open.lowerBound...].prefix(6_000))
        let repair = try XCTUnwrap(body.range(of: "verifyAndRepairKeyConsistency"))
        let guardLine = try XCTUnwrap(body.range(of: "if !result.triedMessageIds.isEmpty {"))
        XCTAssertLessThan(guardLine.lowerBound, repair.lowerBound, "the repair sits under the guard")
        XCTAssertEqual(body.components(separatedBy: "verifyAndRepairKeyConsistency").count - 1, 1)
    }

    /// The INITIATOR side of the same fact. A proactive init opens a session with **each** device
    /// of the account, and the SESSION_RESET_INIT / `session_ready` that speak for one must go to
    /// the device whose ratchet it is — addressed to the account they resolved to the pinned
    /// device, which after a re-init from the peer's other device was a ratchet nobody held.
    ///
    /// Two things are asserted, and they are different: every handshake control emitted after an
    /// init names a device (never `.account(`), and it is a device **from the set the init
    /// returned** — so a second opened device is announced too. Before 2026-09-22 the init
    /// returned one device because it fetched one bundle; the emission naming it was correct and
    /// still reached only half of a two-device account.
    ///
    /// Mutation: emit outside the `for device in opened` loop, or address `.account(userId)`
    /// again — either reddens.
    func testHandshakeControlsAfterAnInitNameTheOpenedDevice() throws {
        let text = try sourceOf("ConstructMessenger/Services/Session/SessionCoordinator.swift")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var offenders: [String] = []
        for (index, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("await self.emitHandshakeControls(") || t.hasPrefix("await self.sendSessionResetInit(") else { continue }
            // Only the emissions that follow an init: the one that just opened the sessions is
            // the one that knows the devices.
            let window = lines[max(0, index - 20)..<index].joined(separator: "\n")
            guard window.contains("initializeSessionProactively(") else { continue }
            if t.contains(".account(") { offenders.append("\(index + 1): \(t)") }
            if !t.contains("device: device") {
                offenders.append("\(index + 1): does not name a device — \(t)")
            }
            if !window.contains("for device in opened") {
                offenders.append("\(index + 1): emitted outside the walk over the opened devices — \(t)")
            }
        }
        XCTAssertEqual(offenders, [], offenders.joined(separator: "\n"))
    }

    private func sourceOf(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try XCTUnwrap(try? String(contentsOf: url, encoding: .utf8))
    }
}
