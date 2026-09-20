//
//  HistorySnapshotDispositionTests.swift
//  ConstructMessengerTests
//
//  One named test per mutation in spec PR 2. A test that cannot go red is not
//  a test.
//

import XCTest
@testable import Construct_Messenger

final class HistorySnapshotDispositionTests: XCTestCase {

    private func failure(_ r: Result<Void, HistorySnapshotError>) -> HistorySnapshotError? {
        if case .failure(let e) = r { return e }
        return nil
    }

    private func manifest(phase: UInt32 = 1, user: Data? = nil, version: UInt32 = 1) -> Construct_Client_History_V1_HistoryManifest {
        var m = Construct_Client_History_V1_HistoryManifest()
        m.formatVersion = version
        m.phase = phase
        m.userID = user ?? Data(repeating: 0x01, count: 16)
        m.snapshotID = Data(repeating: 0xAA, count: 16)
        return m
    }

    /// Mutation: accept() ignores user_id — a snapshot for the wrong account applies.
    func testWrongUserIdIsRejected() {
        let m = manifest(user: Data(repeating: 0x01, count: 16))
        let other = Data(repeating: 0x02, count: 16)
        XCTAssertEqual(failure(HistorySnapshotDisposition.accept(manifest: m, expectedUserId: other)), .userMismatch)
    }

    /// Mutation: accept() treats format_version 2 as v1.
    func testUnknownManifestVersionFails() {
        let m = manifest(version: 2)
        XCTAssertEqual(failure(HistorySnapshotDisposition.accept(manifest: m, expectedUserId: m.userID)), .unknownVersion)
    }

    /// Mutation: phase 0 is treated as transcript.
    func testPhaseZeroFails() {
        let m = manifest(phase: 0)
        XCTAssertEqual(failure(HistorySnapshotDisposition.accept(manifest: m, expectedUserId: m.userID)), .malformed)
    }

    /// Mutation: a live row with the same id is overwritten.
    func testExistingMessageIsKeepExisting() {
        XCTAssertEqual(HistorySnapshotDisposition.messageConflict(existing: true), .keepExisting)
        XCTAssertEqual(HistorySnapshotDisposition.messageConflict(existing: false), .insert)
    }

    /// Mutation: chat upsert uses Chat.id from the offering device.
    func testChatUpsertKeyIsOtherUserIdNeverChatId() {
        let peer = Data(repeating: 0xAB, count: 16)
        XCTAssertEqual(HistorySnapshotDisposition.chatUpsertKey(otherUserId: peer), peer)
    }

    /// Mutation: snapshot false clobbers a profile-true on the receiver.
    func testShareFlagDoesNotClobberTrue() {
        XCTAssertTrue(HistorySnapshotDisposition.contactShareFlag(snapshot: false, alreadyTrueOnReceiver: true))
        XCTAssertTrue(HistorySnapshotDisposition.contactShareFlag(snapshot: true, alreadyTrueOnReceiver: false))
        XCTAssertFalse(HistorySnapshotDisposition.contactShareFlag(snapshot: false, alreadyTrueOnReceiver: false))
    }

    /// Mutation: peer hint is accepted without derive_device_id.
    func testHintIdNotMatchingIdentityKeyIsRejected() {
        let key = Data(repeating: 0x11, count: 32)
        let derived = deriveDeviceId(identityPublicKey: [UInt8](key))
        XCTAssertTrue(HistorySnapshotDisposition.peerDeviceHintAcceptable(deviceId: derived, identityKey: key))
        XCTAssertFalse(
            HistorySnapshotDisposition.peerDeviceHintAcceptable(deviceId: String(repeating: "0", count: 32), identityKey: key)
        )
    }

    /// Mutation: ids are compared case-sensitively and a mixed-case UUID misses.
    func testMessageIdIsLowercased() {
        XCTAssertEqual(
            HistorySnapshotDisposition.lowercaseMessageId("AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"),
            "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        )
    }

    /// Mutation: a record that is not Manifest may lead the stream.
    func testManifestNotFirstFails() {
        XCTAssertFalse(
            HistorySnapshotDisposition.recordOrderAcceptable(phase: 1, previous: nil, incoming: HistoryRecordType.message)
        )
        XCTAssertTrue(
            HistorySnapshotDisposition.recordOrderAcceptable(phase: 1, previous: nil, incoming: HistoryRecordType.manifest)
        )
    }

    /// Mutation: reactions may precede their messages.
    func testReactionBeforeMessageFails() {
        XCTAssertFalse(
            HistorySnapshotDisposition.recordOrderAcceptable(
                phase: 1,
                previous: HistoryRecordType.reaction,
                incoming: HistoryRecordType.message
            )
        )
        XCTAssertTrue(
            HistorySnapshotDisposition.recordOrderAcceptable(
                phase: 1,
                previous: HistoryRecordType.message,
                incoming: HistoryRecordType.reaction
            )
        )
    }

    /// Mutation: MediaBlob is legal in a transcript stream.
    func testMediaBlobInPhase1Fails() {
        XCTAssertFalse(
            HistorySnapshotDisposition.recordOrderAcceptable(
                phase: 1,
                previous: HistoryRecordType.manifest,
                incoming: HistoryRecordType.media
            )
        )
    }

    /// Mutation: a Message is legal in a media-only stream.
    func testTranscriptInPhase2Fails() {
        XCTAssertFalse(
            HistorySnapshotDisposition.recordOrderAcceptable(
                phase: 2,
                previous: HistoryRecordType.manifest,
                incoming: HistoryRecordType.message
            )
        )
    }

    /// Mutation: envelope snapshot_id is not compared to the manifest.
    func testEnvelopeManifestIdMismatchFails() {
        let m = manifest()
        XCTAssertTrue(
            HistorySnapshotDisposition.envelopeMatchesManifest(
                envelopeSnapshotId: m.snapshotID,
                envelopeUserId: m.userID,
                manifest: m
            )
        )
        XCTAssertFalse(
            HistorySnapshotDisposition.envelopeMatchesManifest(
                envelopeSnapshotId: Data(repeating: 0xBB, count: 16),
                envelopeUserId: m.userID,
                manifest: m
            )
        )
    }

    /// Mutation: fp is compared to identity alone, dropping the hybrid half.
    func testQRPinRequiresIdentityAndHybrid() {
        let identity = Data(repeating: 0x11, count: 32)
        let hybrid = Data(repeating: 0xA1, count: 1984)
        let fp = Data(HistorySnapshotDisposition.sha256(identity + hybrid))
        XCTAssertTrue(
            HistorySnapshotDisposition.qrPinMatches(identityPublic: identity, hybridPublic: hybrid, fp: fp)
        )
        let identityOnly = Data(HistorySnapshotDisposition.sha256(identity))
        XCTAssertFalse(
            HistorySnapshotDisposition.qrPinMatches(identityPublic: identity, hybridPublic: hybrid, fp: identityOnly)
        )
    }
}
