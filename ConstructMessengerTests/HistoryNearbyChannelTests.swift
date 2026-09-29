//
//  HistoryNearbyChannelTests.swift
//  ConstructMessengerTests
//
//  CTT1 v2 opening → reply → CTH1 stream, both halves in one process over a memory duplex,
//  framed, signed, checked and sealed by the real core. Bonjour and NWConnection are the only
//  parts left out.
//

import CoreData
import XCTest
@testable import Construct_Messenger

@MainActor
final class HistoryNearbyChannelTests: XCTestCase {

    private let userId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

    /// One device talking to itself: the offering side's peer is this device, as the directory
    /// would list it. The core checks the opening names it and decapsulates with its own Kyber
    /// SPK, so the keys are the core's, not made up here.
    private func keys() throws -> (local: HistoryLocalKeys, peer: HistoryPeer) {
        try CryptoCoreTestBootstrap.ensureCore(localUserId: userId)
        let identityPublic = try CryptoManager.shared.localBundlePublicKeys().identityPublic
        let deviceHex = deriveDeviceId(identityPublicKey: identityPublic)
        let hybrid = try CryptoManager.shared.ensureHybridIdentityPublicKey()
        if try CryptoManager.shared.currentKyberSpkUpload() == nil {
            _ = try CryptoManager.shared.beginKyberSpkRotation()
            CryptoManager.shared.commitKyberSpkRotation()
        }
        let kyber = try XCTUnwrap(try CryptoManager.shared.currentKyberSpkUpload())
        let local = HistoryLocalKeys(
            userIdDashed: userId,
            userIdRaw: try XCTUnwrap(HistoryAccountID.raw(userId)),
            deviceIdHex: deviceHex
        )
        let peer = HistoryPeer(
            deviceIdHex: deviceHex,
            deviceIdRaw: try XCTUnwrap(HistoryChannel.rawDeviceId(deviceHex)),
            identityPublic: identityPublic,
            hybridPublic: hybrid,
            kyberSPKPublic: Data(kyber.publicKey),
            kyberSPKId: kyber.keyId
        )
        return (local, peer)
    }

    func testTranscriptPhaseRoundTripsThroughTheHandshake() async throws {
        let (local, peer) = try keys()
        let offeringStore = PersistenceController(inMemory: true).container.viewContext
        let receivingStore = PersistenceController(inMemory: true).container.viewContext
        let duplex = HistoryMemoryDuplex()
        let sender = HistoryTransferCoordinator()
        let receiver = HistoryTransferCoordinator()

        async let offer: Void = HistoryNearbyChannel.runOffer(
            .transcript, over: duplex.left, peer: peer, local: local, coordinator: sender, context: offeringStore
        )
        let outcome = try await HistoryNearbyChannel.runReceive(
            over: duplex.right,
            local: local,
            pin: .pinned(historyQrFingerprint(identityPublic: peer.identityPublic, hybridPublic: peer.hybridPublic)),
            coordinator: receiver,
            context: receivingStore,
            resolvePeer: { hex in
                XCTAssertEqual(hex, peer.deviceIdHex, "the receiver asks the directory for the device the frame named")
                return peer
            }
        )
        try await offer

        guard case .imported(_, let phase) = outcome else { return XCTFail("expected an import, got \(outcome)") }
        XCTAssertEqual(phase, 1, "phase-1 manifest tells the receiver media follows on a second connection")
        XCTAssertEqual(sender.phase, .chatsTransferred)
    }

    func testSkipOpeningEndsTheOffer() async throws {
        let (local, peer) = try keys()
        let store = PersistenceController(inMemory: true).container.viewContext
        let duplex = HistoryMemoryDuplex()
        let sender = HistoryTransferCoordinator()
        let receiver = HistoryTransferCoordinator()

        async let offer: Void = HistoryNearbyChannel.runOffer(
            .skip, over: duplex.left, peer: peer, local: local, coordinator: sender, context: store
        )
        let outcome = try await HistoryNearbyChannel.runReceive(
            over: duplex.right, local: local, pin: .bundleOnly, coordinator: receiver, context: store,
            resolvePeer: { _ in peer }
        )
        try await offer
        XCTAssertEqual(outcome, .skipped)
        XCTAssertEqual(sender.phase, .skipped)
        XCTAssertEqual(receiver.phase, .skipped)
    }

    /// Flow A with a QR that carried no fp: the frame verifies against the directory and is
    /// still refused, before any secret is touched and before a reply is written.
    func testAbsentPinRefusesBeforeReply() async throws {
        let (local, peer) = try keys()
        let store = PersistenceController(inMemory: true).container.viewContext
        let duplex = HistoryMemoryDuplex()

        let offerTask = Task { @MainActor in
            try await HistoryNearbyChannel.runOffer(
                .transcript, over: duplex.left, peer: peer, local: local,
                coordinator: HistoryTransferCoordinator(), context: store
            )
        }
        do {
            _ = try await HistoryNearbyChannel.runReceive(
                over: duplex.right, local: local, pin: .absent, coordinator: HistoryTransferCoordinator(),
                context: store, resolvePeer: { _ in peer }
            )
            XCTFail("absent pin must refuse")
        } catch {
            guard case .QrPinAbsent = error as? HistoryError else { return XCTFail("\(error)") }
        }
        duplex.right.close()
        offerTask.cancel()
        _ = try? await offerTask.value
    }

    /// The directory names a different device than the frame: identity_mismatch, not a reply.
    func testDirectoryKeyThatDoesNotMatchTheFrameIsRefused() async throws {
        let (local, peer) = try keys()
        var other = peer
        other = HistoryPeer(
            deviceIdHex: peer.deviceIdHex,
            deviceIdRaw: peer.deviceIdRaw,
            identityPublic: Data(repeating: 0x42, count: 32),
            hybridPublic: peer.hybridPublic,
            kyberSPKPublic: peer.kyberSPKPublic,
            kyberSPKId: peer.kyberSPKId
        )
        let store = PersistenceController(inMemory: true).container.viewContext
        let duplex = HistoryMemoryDuplex()
        let offerTask = Task { @MainActor in
            try await HistoryNearbyChannel.runOffer(
                .transcript, over: duplex.left, peer: peer, local: local,
                coordinator: HistoryTransferCoordinator(), context: store
            )
        }
        do {
            _ = try await HistoryNearbyChannel.runReceive(
                over: duplex.right, local: local, pin: .bundleOnly, coordinator: HistoryTransferCoordinator(),
                context: store, resolvePeer: { _ in other }
            )
            XCTFail("a directory key that is not the frame's must refuse")
        } catch {
            guard case .IdentityMismatch = error as? HistoryError else { return XCTFail("\(error)") }
        }
        duplex.right.close()
        offerTask.cancel()
        _ = try? await offerTask.value
    }
}
