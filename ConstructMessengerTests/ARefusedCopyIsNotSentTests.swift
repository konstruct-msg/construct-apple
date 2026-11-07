//
//  ARefusedCopyIsNotSentTests.swift
//  Construct Messenger
//
//  The server can answer a copy to our own device with a refusal, and until 2026-11-07 nothing read
//  the answer: the log said `sent`, `sync_send_failed` stayed at zero, and read markers were dropped
//  as delivered (todo/277, found on the stand of 2026-11-07, `RateLimit` for a device under 48 hours
//  old). Real core, real keys, no server.
//

import XCTest
import SwiftProtobuf
@testable import Construct_Messenger

@MainActor
final class ARefusedCopyIsNotSentTests: XCTestCase {
    private let me = "e7a4e3d2-0000-4000-8000-0000000000aa"
    private let coordinator = MultiDeviceSendCoordinator.shared

    private var mine: OrchestratorCore!
    private var mineId = ""
    private var siblings: [DeviceBundleData] = []
    private var coreBefore: OrchestratorCore?
    private var savedUserId: String?
    private var sendBefore: ((String, String, Data, UInt64, String) async throws -> SendMessageResponse)?
    private var answersByDevice: [String: SendMessageResponse] = [:]
    private var askedDevices: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        savedUserId = AuthSessionManager.shared.currentUserId
        AuthSessionManager.shared.updateUserId(me)
        (mine, mineId) = try makeTestDevice()
        coreBefore = CryptoManager.shared.orchestratorCore
        CryptoManager.shared.orchestratorCore = mine

        var certificate = Shared_Proto_Core_V1_SenderCertificate()
        certificate.senderUserID = me
        StealthSenderService.shared.holdCertificateForTesting(try certificate.serializedData())

        sendBefore = coordinator.sendCopy
        coordinator.sendCopy = { [unowned self] _, _, _, _, device in
            askedDevices.append(device)
            return answersByDevice[device] ?? accepted
        }
    }

    override func tearDown() async throws {
        if let sendBefore { coordinator.sendCopy = sendBefore }
        coordinator.invalidateOwnDeviceCache()
        StealthSenderService.shared.clearCertCache()
        CryptoManager.shared.orchestratorCore = coreBefore
        for sibling in siblings { KeychainManager.shared.deleteSession(for: sibling.deviceId) }
        siblings = []
        answersByDevice = [:]
        askedDevices = []
        if let savedUserId, !savedUserId.isEmpty {
            AuthSessionManager.shared.updateUserId(savedUserId)
        }
        try await super.tearDown()
    }

    // MARK: - What a refusal does to the callers

    /// The control: without it every "not sent" below would pass on a path that never sends.
    func testAnAcceptedCopyIsSentAndNotCountedAsFailed() async throws {
        let sibling = try addSibling()
        let skippedBefore = skipped()

        let sent = await sendMarkers()

        XCTAssertTrue(sent)
        XCTAssertEqual(askedDevices, [sibling])
        XCTAssertEqual(skipped(), skippedBefore)
    }

    /// The case from the stand. Markers answered this way used to leave the outbox for good.
    func testARateLimitedCopyLeavesTheMarkersOwedAndIsCounted() async throws {
        let sibling = try addSibling()
        answersByDevice[sibling] = rateLimited
        let skippedBefore = skipped()

        let sent = await sendMarkers()

        XCTAssertFalse(sent)
        XCTAssertEqual(askedDevices, [sibling], "the copy did reach the server")
        XCTAssertEqual(skipped(), skippedBefore + 1)
    }

    func testABlockedCopyLeavesTheMarkersOwed() async throws {
        let sibling = try addSibling()
        answersByDevice[sibling] = SendMessageResponse(
            messageId: "m", status: "blocked", retryable: false, errorCode: "blocked"
        )

        let sent = await sendMarkers()

        XCTAssertFalse(sent)
    }

    /// One device refused and another took it: the other still gets its copy, and the send as a
    /// whole is not done, whichever device came first.
    func testOneRefusalAmongTwoDevicesIsNotDone() async throws {
        let refused = try addSibling()
        let taken = try addSibling()
        answersByDevice[refused] = rateLimited

        let sent = await sendMarkers()

        XCTAssertFalse(sent)
        XCTAssertEqual(Set(askedDevices), [refused, taken])
    }

    /// The card is sent again on the next publish to whoever is not listed here.
    func testARefusedCardReachedNobody() async throws {
        let sibling = try addSibling()
        answersByDevice[sibling] = rateLimited

        let reached = await coordinator.sendOwnContactCard(
            Data("card".utf8), skipping: [], senderUserId: me, senderDeviceId: mineId
        )

        XCTAssertEqual(reached, [])
    }

    /// The version stays undelivered, so the next connect sends it again.
    func testARefusedProfileIsNotDelivered() async throws {
        let sibling = try addSibling()
        answersByDevice[sibling] = rateLimited

        let sent = await coordinator.sendOwnProfile(
            Data("profile".utf8), senderUserId: me, senderDeviceId: mineId
        )

        XCTAssertFalse(sent)
    }

    // MARK: - Reading the answer

    func testWhatCountsAsARefusal() {
        for status in ["failed", "blocked", "FAILED", "Blocked"] {
            XCTAssertTrue(answer(status).wasRefused, status)
        }
        // "queued": the server holds it. An unknown status reads as sent, as `deliveryStatus` has it.
        for status in ["sent", "delivered", "queued", "success", "something-new"] {
            XCTAssertFalse(answer(status).wasRefused, status)
        }
    }

    func testARefusalStillQueuesOrFailsAMessageAsBefore() {
        XCTAssertEqual(rateLimited.deliveryStatus, .queued)
        XCTAssertEqual(
            SendMessageResponse(messageId: "m", status: "failed", retryable: false).deliveryStatus, .failed
        )
        XCTAssertEqual(
            SendMessageResponse(messageId: "m", status: "blocked", retryable: false).deliveryStatus, .failed
        )
        XCTAssertEqual(answer("delivered").deliveryStatus, .delivered)
        XCTAssertEqual(answer("queued").deliveryStatus, .queued)
        XCTAssertEqual(answer("sent").deliveryStatus, .sent)
    }

    // MARK: - Helpers

    private var accepted: SendMessageResponse { answer("sent") }

    private var rateLimited: SendMessageResponse {
        SendMessageResponse(
            messageId: "m", status: "failed", retryable: true, errorCode: "rateLimit", retryAfterMs: 3_600_000
        )
    }

    private func answer(_ status: String) -> SendMessageResponse {
        SendMessageResponse(messageId: "m", status: status)
    }

    private func skipped() -> Int {
        PerformanceMetrics.shared.count(event: .fanoutDeviceSkipped)
    }

    private func sendMarkers() async -> Bool {
        await coordinator.sendReadMarkers(Data("markers".utf8), senderUserId: me, senderDeviceId: mineId)
    }

    /// A device of ours with a session already open, on the list the send reads.
    private func addSibling() throws -> String {
        let (sibling, siblingId) = try makeTestDevice()
        let keys = try sibling.pqxdhTestBundle()
        _ = try mine.initSession(contactId: siblingId, recipientBundle: keys)
        siblings.append(DeviceBundleData(
            deviceId: siblingId,
            bundle: PublicKeyBundleData(
                userId: me,
                username: "",
                identityPublic: keys.identityPublic,
                signedPrekeyPublic: keys.signedPrekeyPublic,
                signature: keys.signature,
                verifyingKey: keys.verifyingKey,
                suiteId: keys.suiteId,
                spkUploadedAt: keys.spkUploadedAt,
                spkRotationEpoch: keys.spkRotationEpoch,
                kyberSpkUploadedAt: keys.kyberSpkUploadedAt,
                kyberSpkRotationEpoch: keys.kyberSpkRotationEpoch
            ),
            platform: .ios
        ))
        coordinator.holdOwnDeviceListForTesting(siblings)
        return siblingId
    }
}
