//
//  HistoryNearbyChannelTests.swift
//  ConstructMessengerTests
//
//  CTT1 v2 opening → reply → CTH1 stream, both halves in one process over a memory duplex,
//  signed and verified by the real core. Bonjour and NWConnection are the only parts left out.
//

import CoreData
import CryptoKit
import XCTest
@testable import Construct_Messenger

@MainActor
final class HistoryNearbyChannelTests: XCTestCase {

    private let userId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

    /// One device talking to itself: the offering side's peer keys are the receiving side's
    /// local keys. That is enough to exercise every check on the path — ids derive, key ids
    /// match, hybrid signature verifies, KEM decapsulates, chunks open.
    private func keys() throws -> (local: HistoryLocalKeys, peer: HistoryPeerKeys) {
        try CryptoCoreTestBootstrap.ensureCore(localUserId: userId)
        let identity = Curve25519.KeyAgreement.PrivateKey()
        let identityPublic = identity.publicKey.rawRepresentation
        let deviceHex = deriveDeviceId(identityPublicKey: [UInt8](identityPublic))
        let deviceRaw = try XCTUnwrap(HistoryChannel.rawDeviceId(deviceHex))
        let hybrid = try CryptoManager.shared.ensureHybridIdentityPublicKey()
        // The receiving side decapsulates with the core's own Kyber SPK, so the test encapsulates
        // to that key rather than to one made up here.
        if try CryptoManager.shared.currentKyberSpkUpload() == nil {
            _ = try CryptoManager.shared.beginKyberSpkRotation()
            CryptoManager.shared.commitKyberSpkRotation()
        }
        let kyber = try XCTUnwrap(try CryptoManager.shared.currentKyberSpkUpload())
        let local = HistoryLocalKeys(
            userIdDashed: userId,
            userIdRaw: try XCTUnwrap(HistoryAccountID.raw(userId)),
            deviceIdHex: deviceHex,
            deviceIdRaw: deviceRaw,
            identityPrivate: identity.rawRepresentation,
            identityPublic: identityPublic,
            hybridPublic: hybrid,
            kyberSPKId: kyber.keyId
        )
        let peer = HistoryPeerKeys(
            deviceIdHex: deviceHex,
            deviceIdRaw: deviceRaw,
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
            pin: .pinned(HistorySnapshotDisposition.qrFingerprint(identityPublic: peer.identityPublic, hybridPublic: peer.hybridPublic)),
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
            XCTAssertEqual(error as? CTT1V2Error, .qrPinAbsent)
        }
        duplex.right.close()
        offerTask.cancel()
        _ = try? await offerTask.value
    }

    /// The directory names a different device than the frame: identity_mismatch, not a reply.
    func testDirectoryKeyThatDoesNotMatchTheFrameIsRefused() async throws {
        let (local, peer) = try keys()
        var other = peer
        other = HistoryPeerKeys(
            deviceIdHex: peer.deviceIdHex,
            deviceIdRaw: peer.deviceIdRaw,
            identityPublic: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
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
            XCTAssertEqual(error as? CTT1V2Error, .identityMismatch)
        }
        duplex.right.close()
        offerTask.cancel()
        _ = try? await offerTask.value
    }
}
