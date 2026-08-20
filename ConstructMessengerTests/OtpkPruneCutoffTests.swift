//
//  OtpkPruneCutoffTests.swift
//  ConstructMessengerTests
//
//  One rule, and it is a delivery-correctness rule rather than a storage one:
//  a local OTPK private may be deleted only once the server can no longer hand out its public
//  half. The server deletes a key on consumption; an unconsumed key lives until the pool is
//  replaced, and `key-service` soft-expires the old pool strictly under `replace_existing=true`.
//
//  `bcbab02f` (2026-07-28) applied the replace-all id cutoff to the append path too, in order to
//  stop the persisted blob hoarding. Every 20-key append then deleted privates for keys the
//  server was still serving; when a peer's bundle fetch drew one, its 4-DH init could not be
//  reproduced — `OTPK id=… not found` → END_SESSION → forced 3-DH re-init. Observed on device
//  2026-08-01: sender on id 1003070, receiver pruned below 1003210.
//
//  Acceptance is mutation-based: drop the `replaceExisting` guard and
//  testAppend_PrunesNothing must go red.
//

import XCTest
@testable import Construct_Messenger

final class OtpkPruneCutoffTests: XCTestCase {

    /// The regression. An append retires nothing server-side, so nothing local may go.
    func testAppend_PrunesNothing() {
        XCTAssertNil(
            OtpkReplenishmentService.pruneCutoff(replaceExisting: false, minNewId: 1_003_210),
            "append must prune nothing — the server still serves every unconsumed key it holds, "
            + "and deleting its private half costs a session (2026-08-01 field defect)"
        )
    }

    /// The field numbers, as a named case: the id the sender actually used must survive an
    /// append that would previously have cut above it.
    func testAppend_KeepsTheIdTheSenderLaterUsed() {
        let senderUsed: UInt32 = 1_003_070
        let cutoff = OtpkReplenishmentService.pruneCutoff(replaceExisting: false, minNewId: 1_003_230)

        if let cutoff {
            XCTAssertLessThanOrEqual(cutoff, senderUsed,
                                     "pruning at \(cutoff) would delete the private for \(senderUsed)")
        }
        XCTAssertNil(cutoff, "an append must not produce a cutoff at all")
    }

    /// Replace-all is the one upload that retires the server pool, so the cutoff applies there.
    func testReplaceAll_PrunesBelowNewBatchMinusGrace() {
        let cutoff = OtpkReplenishmentService.pruneCutoff(replaceExisting: true, minNewId: 1_003_210)

        XCTAssertEqual(cutoff, 1_003_010, "keep a 200-id grace below the new batch for in-flight first messages")
    }

    /// Grace window wider than the id space: keep everything rather than underflow.
    func testReplaceAll_LowIds_ClampToZero() {
        XCTAssertEqual(OtpkReplenishmentService.pruneCutoff(replaceExisting: true, minNewId: 50), 0)
        XCTAssertEqual(OtpkReplenishmentService.pruneCutoff(replaceExisting: true, minNewId: 200), 0)
    }

    /// Nothing was uploaded — there is no batch to measure against.
    func testNoNewKeys_PrunesNothing() {
        XCTAssertNil(OtpkReplenishmentService.pruneCutoff(replaceExisting: true, minNewId: nil))
        XCTAssertNil(OtpkReplenishmentService.pruneCutoff(replaceExisting: false, minNewId: nil))
    }
}
