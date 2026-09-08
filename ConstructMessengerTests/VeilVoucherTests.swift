//
//  VeilVoucherTests.swift
//  ConstructMessengerTests
//
//  The bootstrap-voucher decisions, and the renewal pacing that the voucher's 45-minute
//  lifetime broke.
//

import XCTest
import GRPCCore
@testable import Construct_Messenger

final class VeilVoucherTests: XCTestCase {

    // MARK: - Renewal pacing

    func testRetryIntervalKeepsTheCeilingForALongLivedCapability() {
        // 90 days left — the old flat hour was right here and stays.
        let interval = VeilCapabilityRenewer.retryInterval(
            secondsLeft: 90 * 24 * 3600, ceiling: 3600, floor: 60
        )
        XCTAssertEqual(interval, 3600)
    }

    func testRetryIntervalFitsInsideAVoucherLifetime() {
        // VOUCHER_TTL_SECS is 2700. A flat hour meant one failed attempt consumed the only
        // retry the capability would ever get, and it then expired — taking the transport
        // the peer needs to register in the first place.
        let interval = VeilCapabilityRenewer.retryInterval(
            secondsLeft: 2700, ceiling: 3600, floor: 60
        )
        XCTAssertLessThan(interval, 2700)
        XCTAssertEqual(interval, 900)
        XCTAssertGreaterThanOrEqual(2700 / interval, 2, "a voucher must get more than one attempt")
    }

    func testRetryIntervalNeverDropsBelowTheFloor() {
        // Nearly dead: without a floor this becomes a retry loop on every VEIL RPC success.
        XCTAssertEqual(
            VeilCapabilityRenewer.retryInterval(secondsLeft: 30, ceiling: 3600, floor: 60), 60
        )
        XCTAssertEqual(
            VeilCapabilityRenewer.retryInterval(secondsLeft: 0, ceiling: 3600, floor: 60), 60
        )
    }

    // MARK: - Availability

    func testVoucherOfferedWhenNeverAsked() {
        XCTAssertTrue(VeilVoucherAvailability.isOffered(unavailableUntil: nil, now: Date()))
    }

    func testVoucherHiddenInsideTheSuppressionWindow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let until = now.addingTimeInterval(3600)
        XCTAssertFalse(VeilVoucherAvailability.isOffered(unavailableUntil: until, now: now))
    }

    func testVoucherReappearsAfterTheWindow() {
        // The flag is an operator switch. A client that latched "unavailable" for the life
        // of the install would need an app update to notice it being turned on.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let until = now.addingTimeInterval(-1)
        XCTAssertTrue(VeilVoucherAvailability.isOffered(unavailableUntil: until, now: now))
    }

    // MARK: - Error mapping

    @MainActor
    func testUnimplementedHidesTheAction() {
        let state = VeilVoucherViewModel.state(
            for: RPCError(code: .unimplemented, message: "issue bootstrap voucher is not enabled")
        )
        XCTAssertEqual(state, .unavailable)
    }

    @MainActor
    func testQuotaCarriesTheRetryTime() {
        let state = VeilVoucherViewModel.state(
            for: RPCError(code: .resourceExhausted, message: "retry_after=7200")
        )
        XCTAssertEqual(state, .quota(retryAfter: 7200))
    }

    @MainActor
    func testQuotaWithoutAParsableTimeStillReadsAsQuota() {
        let state = VeilVoucherViewModel.state(
            for: RPCError(code: .resourceExhausted, message: "too many")
        )
        XCTAssertEqual(state, .quota(retryAfter: 0))
    }

    @MainActor
    func testOtherFailuresAreGeneric() {
        // failed_precondition ("no relays configured") is an operator problem, not something
        // to explain to the user — and naming it would say something about the deployment.
        guard case .failed = VeilVoucherViewModel.state(
            for: RPCError(code: .failedPrecondition, message: "no relays configured on veil-service")
        ) else {
            return XCTFail("expected a generic failure")
        }
        guard case .failed = VeilVoucherViewModel.state(
            for: RPCError(code: .unavailable, message: "transport down")
        ) else {
            return XCTFail("expected a generic failure")
        }
    }

    @MainActor
    func testRetryAfterParsing() {
        XCTAssertEqual(VeilVoucherViewModel.retryAfterSeconds(from: "retry_after=86400"), 86400)
        XCTAssertEqual(VeilVoucherViewModel.retryAfterSeconds(from: "x retry_after=1 y"), 1)
        XCTAssertNil(VeilVoucherViewModel.retryAfterSeconds(from: "retry_after="))
        XCTAssertNil(VeilVoucherViewModel.retryAfterSeconds(from: "nothing here"))
    }

    // MARK: - Access status says whether, not where

    func testAccessConfiguredCountsAnyDialableRelay() {
        // The old check named one hardcoded seed relay, so a device provisioned by a
        // voucher reported "no access configured" while it was connected through one.
        let candidates = ["seed.example:443", "learned.example:443"]
        let configured = VeilAccessStatus.configured(candidates: candidates) {
            $0 == "learned.example:443"
        }
        XCTAssertEqual(configured, ["learned.example:443"])
    }

    func testAccessNotConfiguredWhenNothingStored() {
        XCTAssertTrue(
            VeilAccessStatus.configured(candidates: ["a.example:443"]) { _ in false }.isEmpty
        )
    }

    func testAccessStatusDeduplicatesCandidates() {
        // `cachedRelayAddresses()` concatenates learned + cached + discovered; a relay in
        // two of those must not be counted twice.
        let configured = VeilAccessStatus.configured(
            candidates: ["a.example:443", "a.example:443"]
        ) { _ in true }
        XCTAssertEqual(configured, ["a.example:443"])
    }

    // MARK: - Redemption

    @MainActor
    func testRedeemingGarbageArmsNothing() {
        // `redeem` arms the transport only on success. A failed scan — a QR from some
        // other app, a truncated paste — must not push a pool or force VEIL on, or a
        // mistyped code would strand an onboarding device on a transport it has no
        // credential for.
        let before = VeilLearnedFrontStore.shared.addresses()
        let result = VeilVoucherRedemption.redeem("not-a-voucher")
        guard case .failure = result else {
            return XCTFail("garbage must not import")
        }
        XCTAssertEqual(VeilLearnedFrontStore.shared.addresses(), before)
    }

    @MainActor
    func testAContactCodeIsNotClaimedByTheVoucherReader() {
        // The contact scanners consult `messageIfVoucher` first. It must claim only the
        // explicit veil-config form — a contact link that fell through to the voucher
        // importer would fail with the wrong message, which is the bug in reverse.
        for text in [
            "konstruct://contact?u=abc&k=def",
            "https://konstruct.cc/u/someone",
            "",
            "not a url at all",
        ] {
            XCTAssertNil(VeilVoucherRedemption.messageIfVoucher(text),
                         "must not claim \(text.isEmpty ? "<empty>" : text)")
        }
    }

    @MainActor
    func testCapabilityTargetPrefersALearnedFrontOverTheSeed() throws {
        // The bug behind a voucher-bootstrapped device losing its front after 45
        // minutes: the pipeline asked for `VEILConfig.ruRelayAddress` no matter which
        // relay the device was actually on, so the learned front's B2 expired with no
        // replacement ever requested.
        let store = VeilLearnedFrontStore.shared
        let address = "target.example:443"
        try XCTSkipUnless(store.pin(for: address) == nil, "address must start unlearned")
        defer { store.remove(address) }

        let seed = VeilProxyManager.shared.capabilityTargetAddress()
        XCTAssertEqual(seed, VEILConfig.ruRelayAddress,
                       "with nothing learned and no active relay, the seed is the target")

        XCTAssertTrue(store.save(
            address: address, sni: "target.example", spki: String(repeating: "e", count: 64)
        ))
        XCTAssertEqual(VeilProxyManager.shared.capabilityTargetAddress(), address,
                       "a learned front must be the pipeline's target, not the seed")
    }

    @MainActor
    func testAMalformedVoucherLinkIsClaimedAndReportedAsAVoucher() {
        // Claimed (so the contact parser never sees it) but refused, with the importer's
        // own message rather than "scan a Konstruct contact code".
        let message = VeilVoucherRedemption.messageIfVoucher("konstruct://veil-config?d=!!!")
        XCTAssertNotNil(message)
        XCTAssertNotEqual(message, NSLocalizedString("veil_config_import_ok", comment: ""))
    }
}
