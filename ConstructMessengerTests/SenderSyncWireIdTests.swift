//
//  SenderSyncWireIdTests.swift
//  ConstructMessengerTests
//
//  Delivery is not per device. `messaging-service/src/core.rs` fans a message out with
//  `fetch_recipient_device_ids`, writing the same envelope to every one of the recipient's
//  per-device streams, so an account with three devices receives on each of them the two copies
//  meant for the other two. The `-ss-<tag>` suffix the sender writes is what tells them apart.
//
//  Acceptance is mutation-based; each test names the mutation that must redden it.
//

import XCTest
@testable import Construct_Messenger

final class SenderSyncWireIdTests: XCTestCase {

    private let base = "34f009c9-caa1-41a3-964e-40af9f3129a7"
    private let deviceId = "b3ed60ab5d0ef2c01f292a40bcdc3465"

    // MARK: - Reading the tag

    func testSingleChunkIdYieldsTheTargetTag() {
        XCTAssertEqual(SenderSyncWireId.targetDeviceTag(of: "\(base)-ss-b3ed60ab"), "b3ed60ab")
    }

    /// A multi-chunk copy carries the chunk index after the tag. Cutting it is what keeps chunk 3
    /// of a copy for another device from reading as a tag of its own.
    ///
    /// Mutation: drop the `-c` trim — the tag becomes "b3ed60ab-c3", matches nothing, and every
    /// chunk after the first is treated as foreign, so multi-chunk syncs never assemble.
    func testMultiChunkIdYieldsTheSameTag() {
        XCTAssertEqual(SenderSyncWireId.targetDeviceTag(of: "\(base)-ss-b3ed60ab-c3"), "b3ed60ab")
    }

    /// An ordinary message id is not a sender-sync id, and must not be read as one — otherwise
    /// every incoming message would be tested against a device tag it never had.
    func testOrdinaryMessageIdHasNoTag() {
        XCTAssertNil(SenderSyncWireId.targetDeviceTag(of: base))
        XCTAssertNil(SenderSyncWireId.targetDeviceTag(of: "\(base)-c2"))
        XCTAssertNil(SenderSyncWireId.targetDeviceTag(of: ""))
    }

    // MARK: - Matching it against our own device

    /// The sender writes `deviceId.prefix(8)`, so this has to be a prefix test. Comparing the full
    /// id against the truncated tag never matches, and *every* copy — including our own — would be
    /// dropped as foreign, which is a worse outcome than the noise this guard removes.
    ///
    /// Mutation: `deviceId == tag` — sender sync stops working entirely.
    func testOurOwnTagMatchesTheFullDeviceId() {
        XCTAssertTrue(SenderSyncWireId.tag(matches: deviceId, tag: "b3ed60ab"))
    }

    /// Mutation: `return true` — foreign copies are no longer skipped and we are back to failing
    /// a decrypt against every candidate session for messages that were never ours.
    func testAnotherDevicesTagDoesNotMatch() {
        XCTAssertFalse(SenderSyncWireId.tag(matches: deviceId, tag: "bfbcef09"))
    }

    /// An empty tag must never match: it would make every copy look like ours.
    func testEmptyTagNeverMatches() {
        XCTAssertFalse(SenderSyncWireId.tag(matches: deviceId, tag: ""))
    }

    /// End to end on the pair of devices from the 2026-08-17 logs: annie's account had
    /// `bfbcef09…` and `b3ed60ab…`, and each was receiving the other's copies.
    func testTheTwoDevicesFromTheIncidentSortTheirOwnCopies() throws {
        let mine = "bfbcef09a4db589922c2cfd0cf34885a"
        let theirs = "b3ed60ab5d0ef2c01f292a40bcdc3465"

        let forMe = try XCTUnwrap(SenderSyncWireId.targetDeviceTag(of: "\(base)-ss-bfbcef09"))
        let forThem = try XCTUnwrap(SenderSyncWireId.targetDeviceTag(of: "\(base)-ss-b3ed60ab"))

        XCTAssertTrue(SenderSyncWireId.tag(matches: mine, tag: forMe))
        XCTAssertFalse(SenderSyncWireId.tag(matches: mine, tag: forThem))
        XCTAssertTrue(SenderSyncWireId.tag(matches: theirs, tag: forThem))
        XCTAssertFalse(SenderSyncWireId.tag(matches: theirs, tag: forMe))
    }
}
