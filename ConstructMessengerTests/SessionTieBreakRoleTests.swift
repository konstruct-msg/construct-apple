//
//  SessionTieBreakRoleTests.swift
//  ConstructMessengerTests
//
//  The tie-break decides, symmetrically across two devices, which side is INITIATOR and which
//  waits as RESPONDER. A disagreement is not a retryable error — it is both-initiator or
//  both-responder, permanently.
//
//  The rule itself is the core's and is tested there (`message_router.rs`). What is testable only
//  here, and what actually broke, is **which pair we hand it**: the core ranks two device ids, and
//  a caller that ranks two account ids has answered a different question with the same type.
//
//  Acceptance is mutation-based; each test names the mutation that must redden it.
//

import XCTest
import CryptoKit
@testable import Construct_Messenger

final class SessionTieBreakRoleTests: XCTestCase {

    private let peerUserId = "289b95ca-8260-4b99-a79a-acaba5681b71"
    private var peerKey = Data()
    private var peerDeviceId = ""

    override func setUp() {
        super.setUp()
        peerKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        peerDeviceId = deriveDeviceId(identityPublicKey: [UInt8](peerKey))
        SessionAddressing.pinnedIdentityKeyOverrideForTesting = { [peerKey, peerUserId] asked in
            asked == peerUserId ? peerKey : nil
        }
    }

    override func tearDown() {
        SessionAddressing.pinnedIdentityKeyOverrideForTesting = nil
        SessionAddressing.localIdentityOverrideForTesting = nil
        super.tearDown()
    }

    /// A device id one hex digit above / below the peer's, so "who is higher" is decided by the
    /// device space and nothing else.
    private func deviceId(relativeToPeer higher: Bool) -> String {
        var chars = Array(peerDeviceId)
        // Walk from the end for a digit that can move in the wanted direction without carrying.
        for i in stride(from: chars.count - 1, through: 0, by: -1) {
            let digits = Array("0123456789abcdef")
            guard let at = digits.firstIndex(of: chars[i]) else { continue }
            let want = higher ? at + 1 : at - 1
            guard digits.indices.contains(want) else { continue }
            chars[i] = digits[want]
            return String(chars)
        }
        XCTFail("no movable digit in \(peerDeviceId)")
        return peerDeviceId
    }

    // MARK: - The rule

    /// The core owns the comparison; this pins that we read its answer the right way round.
    ///
    /// Mutation: read `"Responder"` as `.initiator` (invert the comparison in
    /// `SessionAddressing.role`) — this reddens.
    func testTheHigherIdInitiates() {
        XCTAssertEqual(SessionAddressing.role(mine: "bob", theirs: "alice"), .initiator)
        XCTAssertEqual(SessionAddressing.role(mine: "alice", theirs: "bob"), .responder)
    }

    /// Exactly one side of any pair initiates. This is the property whose failure is the deadlock.
    func testExactlyOneSideOfAPairInitiates() {
        for _ in 0..<200 {
            let a = UUID().uuidString.lowercased()
            let b = UUID().uuidString.lowercased()
            guard a != b else { continue }
            let aInitiates = SessionAddressing.role(mine: a, theirs: b) == .initiator
            let bInitiates = SessionAddressing.role(mine: b, theirs: a) == .initiator
            XCTAssertNotEqual(aInitiates, bInitiates, "both sides claimed the same role: \(a) / \(b)")
        }
    }

    /// The core's wire name is the one spelling of the role, and reading it is a comparison against
    /// a literal — so a change of spelling on either side has to redden something.
    ///
    /// Mutation: compare against `"initiator"` lowercased — this reddens.
    func testTheCoreAnswersWithTheWireSpelling() {
        XCTAssertEqual(tieBreakRole(myId: "bob", peerId: "alice"), "Initiator")
        XCTAssertEqual(tieBreakRole(myId: "alice", peerId: "bob"), "Responder")
    }

    // MARK: - The pair

    /// The defect this replaced: the core ranked (our device, their device) while the app ranked
    /// (our account, their account). Both comparisons were correct; they ranked different pairs and
    /// agreed about half the time.
    ///
    /// Here our device id is **below** the peer's while our account id is **above** it, so an
    /// implementation that resolved the account space would answer `true`.
    ///
    /// Mutation: rank `AuthSessionManager.currentUserId` against `peerId` instead of resolving both
    /// through the seam — this reddens.
    func testTheRankedPairIsTwoDeviceIds() {
        SessionAddressing.localIdentityOverrideForTesting = deviceId(relativeToPeer: false)
        XCTAssertGreaterThan("ffffffff-ffff-ffff-ffff-ffffffffffff", peerUserId,
                             "the account-space comparison must point the other way")
        XCTAssertEqual(SessionAddressing.isNaturalInitiator(againstPeer: peerUserId), false)

        SessionAddressing.localIdentityOverrideForTesting = deviceId(relativeToPeer: true)
        XCTAssertEqual(SessionAddressing.isNaturalInitiator(againstPeer: peerUserId), true)
    }

    /// A peer already named by a device id is ranked as given — the per-device paths reach here
    /// holding one.
    func testAPeerNamedByItsDeviceRanksTheSame() {
        SessionAddressing.localIdentityOverrideForTesting = deviceId(relativeToPeer: true)
        XCTAssertEqual(SessionAddressing.isNaturalInitiator(againstPeer: peerDeviceId), true)
        XCTAssertEqual(SessionAddressing.isNaturalInitiator(againstPeer: peerUserId),
                       SessionAddressing.isNaturalInitiator(againstPeer: peerDeviceId))
    }

    /// Two devices of **one account** — the pair the account space cannot rank at all.
    ///
    /// A cross-account pair exposes the old defect only half the time, by coincidence of which
    /// ids sort where. This pair exposes it always: siblings share an account id, so the account
    /// comparison sees `myId == peerId` and elects nobody, while the device comparison elects
    /// exactly one. Multi-device is what made this pair real, and it is the case that deadlocks
    /// rather than merely disagreeing.
    ///
    /// The three-simulator stand could not run it: the silent-re-init picker lists contacts, and
    /// a sibling device is not a contact. So it is pinned here instead.
    ///
    /// Mutation: rank `AuthSessionManager.currentUserId` against the peer's account id — both
    /// sides then answer `false` and this reddens on whichever side should have initiated.
    func testTwoDevicesOfOneAccountStillElectExactlyOneInitiator() {
        // One account, two devices. The seam is handed the sibling's device id directly, which is
        // what the per-device paths hold.
        let sibling = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let siblingDeviceId = deriveDeviceId(identityPublicKey: [UInt8](sibling))
        XCTAssertNotEqual(siblingDeviceId, peerDeviceId)

        let mine = deviceId(relativeToPeer: true)

        // Both halves go through the production seam — this is the same question asked on two
        // devices, which is the only way the answer's symmetry can be asserted at all. Reading one
        // side through `role` directly would leave the mutation "always answer false" surviving
        // half the time, on whichever way the other half happened to fall.
        SessionAddressing.localIdentityOverrideForTesting = mine
        let weInitiate = SessionAddressing.isNaturalInitiator(againstPeer: siblingDeviceId)

        SessionAddressing.localIdentityOverrideForTesting = siblingDeviceId
        let theyInitiate = SessionAddressing.isNaturalInitiator(againstPeer: mine)

        XCTAssertNotNil(weInitiate)
        XCTAssertNotNil(theyInitiate)
        XCTAssertNotEqual(weInitiate, theyInitiate,
                          "both devices of one account claimed the same role: \(mine) / \(siblingDeviceId)")
    }

    // MARK: - When the pair cannot be ranked

    /// A peer whose key we never pinned has no name in the crypto space, so there is no pair. The
    /// seam says so rather than ranking something else.
    ///
    /// Mutation: fall back to the account id when the peer cannot be named — this reddens, and it
    /// is the fallback that produced the defect above.
    func testAnUnnameablePeerCannotBeRanked() {
        SessionAddressing.localIdentityOverrideForTesting = deviceId(relativeToPeer: true)
        XCTAssertNil(SessionAddressing.isNaturalInitiator(againstPeer: "8c1f0b2e-0000-4000-8000-000000000001"))
        XCTAssertNil(SessionAddressing.isNaturalInitiator(againstPeer: ""))
    }

    /// No local identity means no half of ours to rank. Every caller treats this as "not the
    /// initiator", which is the branch that raises no init.
    ///
    /// Mutation: rank with an empty local identity — the empty string loses every comparison, so
    /// this would answer `false` rather than `nil` and the distinction would be gone.
    func testWithoutALocalIdentityThereIsNoPair() {
        SessionAddressing.localIdentityOverrideForTesting = ""
        XCTAssertNil(SessionAddressing.isNaturalInitiator(againstPeer: peerUserId))
    }

    /// Self, or an echo of our own copy. Nobody initiates against themselves, and this is a
    /// decided `false` — not an unrankable pair.
    ///
    /// The answer comes from the core, which is why there is no equality guard on this side: one
    /// was written, mutation-tested, found to have no observable effect, and dropped. This pins the
    /// property **across the boundary** — the core's own `test_an_id_does_not_win_against_itself`
    /// pins it there, and this fails if we ever add a Swift-side special case that disagrees.
    func testNobodyInitiatesAgainstThemselves() {
        SessionAddressing.localIdentityOverrideForTesting = peerDeviceId
        XCTAssertEqual(SessionAddressing.isNaturalInitiator(againstPeer: peerDeviceId), false)
        XCTAssertEqual(SessionAddressing.isNaturalInitiator(againstPeer: peerUserId), false)
    }
}
