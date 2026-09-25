//
//  HistoryNearbyChannel.swift
//  Construct Messenger
//
//  CTT1 v2 over the same Bonjour/TCP pipe the v1 backup uses. One connection per phase (K18):
//  the offering device advertises, sends the opening, reads the reply, streams CTH1; the new
//  device browses, verifies, replies, imports as records arrive. Keys are HistoryChannel's;
//  frames are CTT1V2Frames'; verification is CTT1V2Verify's. This file only moves bytes and
//  orders the calls. No PIN: the discovery tag is scope, the hybrid signatures and the QR pin
//  are the authentication.
//

import CoreData
import CryptoKit
import Foundation
import Network

// MARK: - NWConnection as a byte pipe

final class NWConnectionTransport: HistoryByteTransport, @unchecked Sendable {
    private let conn: NWConnection

    init(_ conn: NWConnection) {
        self.conn = conn
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    func receiveExact(_ count: Int) async throws -> Data {
        var buffer = Data()
        buffer.reserveCapacity(count)
        while buffer.count < count {
            let remaining = count - buffer.count
            let chunk = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                conn.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, isComplete, error in
                    if let error {
                        cont.resume(throwing: error)
                    } else if let data, !data.isEmpty {
                        cont.resume(returning: data)
                    } else if isComplete {
                        cont.resume(throwing: NearbyTransferError.connectionClosed)
                    } else {
                        cont.resume(returning: Data())
                    }
                }
            }
            buffer.append(chunk)
        }
        return buffer
    }

    func close() {
        conn.cancel()
    }
}

// MARK: - Channel

@MainActor
final class HistoryNearbyChannel {

    enum OfferKind: Equatable {
        case transcript
        case media
        case skip
    }

    enum ReceiveOutcome: Equatable {
        /// The offering device sent type 0x03: continue without history.
        case skipped
        /// One phase imported; `manifestPhase` says whether media follows on a second connection.
        case imported(HistoryImportSummary, manifestPhase: UInt32)
    }

    /// Spec §6 race after ConfirmDeviceLink: the directory may not list the new device's keys
    /// yet. 2 s × 15, then the caller offers a file.
    static let peerKeysAttempts = 15
    static let peerKeysRetryDelay: Duration = .seconds(2)

    private let queue = DispatchQueue(label: "com.construct.history.transfer", qos: .userInitiated)
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var transport: NWConnectionTransport?

    func cancel() {
        listener?.cancel()
        browser?.cancel()
        transport?.close()
        listener = nil
        browser = nil
        transport = nil
    }

    // MARK: - Offering device

    static func waitForPeerKeys(
        ownUserId: String,
        peerDeviceId: String,
        pinnedIdentity: Data?
    ) async throws -> HistoryPeerKeys {
        var lastError: Error = HistoryChannelError.peerNotInDirectory
        for attempt in 1...peerKeysAttempts {
            try Task.checkCancellation()
            do {
                return try await HistoryChannel.fetchPeerKeys(
                    ownUserId: ownUserId,
                    peerDeviceId: peerDeviceId,
                    pinnedIdentity: pinnedIdentity
                )
            } catch CTT1V2Error.qrPinMismatch {
                throw CTT1V2Error.qrPinMismatch // a hard stop, never a retry
            } catch {
                lastError = error
                Log.info("history_peer_keys_wait attempt=\(attempt) reason=\(error)", category: "HistorySync")
                if attempt < peerKeysAttempts { try await Task.sleep(for: peerKeysRetryDelay) }
            }
        }
        throw lastError
    }

    /// Advertise, accept one connection, run the CTT1 v2 opening/reply, then stream one phase.
    /// `context` is a background context; the encoder is driven on its queue.
    func offer(
        _ kind: OfferKind,
        peer: HistoryPeerKeys,
        local: HistoryLocalKeys,
        coordinator: HistoryTransferCoordinator,
        context: NSManagedObjectContext
    ) async throws {
        let tag = HistorySnapshotDisposition.discoveryTag(userIdDashed: local.userIdDashed, newDeviceIdHex: peer.deviceIdHex)
        let instanceName = TransferCrypto.discoveryInstanceName(tag: tag)
        let conn = try await acceptConnection(instanceName: instanceName)
        let transport = NWConnectionTransport(conn)
        self.transport = transport
        defer { transport.close(); self.transport = nil }
        try await Self.runOffer(kind, over: transport, peer: peer, local: local, coordinator: coordinator, context: context)
    }

    /// The offering side over any byte pipe — the in-process tests drive it over a duplex.
    static func runOffer(
        _ kind: OfferKind,
        over transport: HistoryByteTransport,
        peer: HistoryPeerKeys,
        local: HistoryLocalKeys,
        coordinator: HistoryTransferCoordinator,
        context: NSManagedObjectContext
    ) async throws {
        let identity = HistorySnapshotIdentity.make(userId: local.userIdDashed, sourceDeviceId: local.deviceIdHex)
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let isSkip = kind == .skip
        let kem: MlkemEncapsulation? = isSkip ? nil : try mlkem1024Encapsulate(publicKey: [UInt8](peer.kyberSPKPublic))

        var opening = CTT1V2Opening(
            senderEphPub: eph.publicKey.rawRepresentation,
            type: isSkip ? .historySyncSkipped : .historySync,
            payloadLength: 0,
            senderIdentityPub: local.identityPublic,
            senderHybridPub: local.hybridPublic,
            snapshotId: isSkip ? Data(count: CTT1V2Layout.snapshotIdCount) : identity.snapshotId,
            senderDeviceId: local.deviceIdRaw,
            receiverDeviceId: peer.deviceIdRaw,
            receiverKyberKeyId: peer.kyberSPKId,
            kemCt: kem.map { Data($0.ciphertext) } ?? Data(count: CTT1V2Layout.kemCtCount),
            signature: Data()
        )
        opening.signature = try CryptoManager.shared.signHybrid(opening.taggedMessage)
        try await transport.send(try opening.serialize())
        Log.info("history_opening_sent kind=\(kind) to=\(peer.deviceIdHex.prefix(8))…", category: "HistorySync")

        if isSkip {
            coordinator.markSkipped()
            return
        }
        guard let kem else { throw CTT1V2Error.malformed }

        let reply = try CTT1V2Reply.parse(try await transport.receiveExact(CTT1V2Layout.replyCount))
        if case .failure(let reason) = CTT1V2Verify.reply(
            reply,
            opening: opening,
            knownIdentity: peer.identityPublic,
            knownHybrid: peer.hybridPublic
        ) {
            Log.error("history_reply_refused reason=\(reason)", category: "HistorySync")
            throw reason
        }

        let receiverEph = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: reply.receiverEphPub)
        let ecdh = try eph.sharedSecretFromKeyAgreement(with: receiverEph).withUnsafeBytes { Data($0) }
        let session = HistoryStreamSession(
            key: TransferCrypto.deriveChannelKey(
                ecdh: ecdh,
                kemSharedSecret: Data(kem.sharedSecret),
                salt: .nearby,
                snapshotId: identity.snapshotId
            ),
            snapshotId: identity.snapshotId,
            userId: local.userIdRaw
        )

        // The encoder walks Core Data synchronously when the stream is created, so it lives
        // entirely on the context's queue; only the buffered stream and the final counters
        // come back out. The records then flow to the sender from the buffer.
        let counters: HistoryEncodeCounters
        switch kind {
        case .transcript:
            let (records, c) = await context.perform {
                let encoder = HistorySnapshotEncoder(identity: identity)
                return (encoder.encodeTranscript(context: context), encoder.counters)
            }
            counters = c
            try await coordinator.sendTranscript(records: records, over: transport, session: session)
        case .media:
            let (records, c) = await context.perform {
                let encoder = HistorySnapshotEncoder(identity: identity)
                return (encoder.encodeMedia(context: context), encoder.counters)
            }
            counters = c
            try await coordinator.sendMedia(records: records, over: transport, session: session)
        case .skip:
            counters = HistoryEncodeCounters()
        }
        Log.info(
            "history_phase_sent kind=\(kind) undecryptable=\(counters.messageUndecryptable) control=\(counters.messageControlSkipped) unconvertible=\(counters.messageLegacyUnconvertible) media_too_large=\(counters.mediaTooLarge)",
            category: "HistorySync"
        )
    }

    private func acceptConnection(instanceName: String) async throws -> NWConnection {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let listener = try NWListener(using: params)
        listener.service = NWListener.Service(name: instanceName, type: NearbyTransferService.serviceType)
        self.listener = listener
        let conn = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<NWConnection, Error>) in
            let flag = ResumeOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .failed(let error):
                    guard !flag.done else { return }
                    flag.done = true
                    cont.resume(throwing: error)
                case .cancelled:
                    guard !flag.done else { return }
                    flag.done = true
                    cont.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.newConnectionHandler = { connection in
                guard !flag.done else { connection.cancel(); return }
                flag.done = true
                cont.resume(returning: connection)
            }
            listener.start(queue: queue)
        }
        listener.cancel()
        self.listener = nil
        conn.start(queue: queue)
        try await waitForReady(conn)
        return conn
    }

    // MARK: - New device

    /// How the new device learns the offering device's keys: the directory, by default.
    typealias PeerResolver = @MainActor (_ deviceIdHex: String) async throws -> HistoryPeerKeys

    static func directoryResolver(ownUserId: String) -> PeerResolver {
        { deviceIdHex in
            try await HistoryChannel.fetchPeerKeys(ownUserId: ownUserId, peerDeviceId: deviceIdHex, pinnedIdentity: nil)
        }
    }

    /// Browse for the offering device, verify its opening, reply, import one phase.
    func receive(
        local: HistoryLocalKeys,
        pin: HistoryQRPin,
        coordinator: HistoryTransferCoordinator,
        context: NSManagedObjectContext
    ) async throws -> ReceiveOutcome {
        let tag = HistorySnapshotDisposition.discoveryTag(userIdDashed: local.userIdDashed, newDeviceIdHex: local.deviceIdHex)
        let instanceName = TransferCrypto.discoveryInstanceName(tag: tag)
        let conn = try await connect(instanceName: instanceName)
        let transport = NWConnectionTransport(conn)
        self.transport = transport
        defer { transport.close(); self.transport = nil }
        return try await Self.runReceive(
            over: transport,
            local: local,
            pin: pin,
            coordinator: coordinator,
            context: context,
            resolvePeer: Self.directoryResolver(ownUserId: local.userIdDashed)
        )
    }

    /// The new device's side over any byte pipe.
    static func runReceive(
        over transport: HistoryByteTransport,
        local: HistoryLocalKeys,
        pin: HistoryQRPin,
        coordinator: HistoryTransferCoordinator,
        context: NSManagedObjectContext,
        resolvePeer: PeerResolver
    ) async throws -> ReceiveOutcome {
        // Two-step read: 46, then 6529 only for v2. History on v1 is refused before anything else.
        let prefixBytes = try await transport.receiveExact(CTT1V2Layout.prefixCount)
        let prefix = try CTT1V2Prefix.parse(prefixBytes)
        if case .failure(let reason) = CTT1V2Verify.historyAccepts(prefix: prefix) {
            throw reason
        }
        let rest = try await transport.receiveExact(CTT1V2Layout.openingAfterPrefixCount)
        let opening = try CTT1V2Opening.parse(prefixBytes + rest)

        // The frame names the offering device; its keys come from our own account's directory
        // entry, never from the frame.
        let senderHex = opening.senderDeviceId.map { String(format: "%02x", $0) }.joined()
        let peer = try await resolvePeer(senderHex)
        let known = CTT1V2Verify.Known(
            identityPublic: peer.identityPublic,
            hybridPublic: peer.hybridPublic,
            localDeviceId: local.deviceIdRaw,
            kyberKeyId: local.kyberSPKId,
            pin: pin
        )
        if case .failure(let reason) = CTT1V2Verify.opening(opening, known: known) {
            Log.error("history_opening_refused reason=\(reason)", category: "HistorySync")
            throw reason
        }
        if case .bundleOnly = pin {
            Log.info("history_trust root=bundle_only (Flow B residual)", category: "HistorySync")
        }
        if opening.type == .historySyncSkipped {
            coordinator.markSkipped()
            return .skipped
        }

        // Verified: reply, then touch the secrets.
        let eph = Curve25519.KeyAgreement.PrivateKey()
        var reply = CTT1V2Reply(
            receiverEphPub: eph.publicKey.rawRepresentation,
            receiverIdentityPub: local.identityPublic,
            receiverHybridPub: local.hybridPublic,
            signature: Data()
        )
        reply.signature = try CryptoManager.shared.signHybrid(reply.taggedMessage(
            senderEphPub: opening.senderEphPub,
            snapshotId: opening.snapshotId,
            senderDeviceId: opening.senderDeviceId,
            receiverDeviceId: opening.receiverDeviceId,
            kemCt: opening.kemCt
        ))
        try await transport.send(try reply.serialize())

        let senderEph = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: opening.senderEphPub)
        let ecdh = try eph.sharedSecretFromKeyAgreement(with: senderEph).withUnsafeBytes { Data($0) }
        let kemSS = try CryptoManager.shared.kyberPrekeyDecapsulate(keyId: local.kyberSPKId, ciphertext: opening.kemCt)
        let session = HistoryStreamSession(
            key: TransferCrypto.deriveChannelKey(
                ecdh: ecdh,
                kemSharedSecret: kemSS,
                salt: .nearby,
                snapshotId: opening.snapshotId
            ),
            snapshotId: opening.snapshotId,
            userId: local.userIdRaw
        )

        var manifestPhase: UInt32 = 0
        let summary = try await coordinator.importStream(
            over: transport,
            session: session,
            expectedUserId: local.userIdDashed,
            in: context,
            onManifest: { manifestPhase = $0.phase }
        )
        Log.info(
            "history_snapshot_done source=nearby phase=\(manifestPhase) applied=\(summary.applied) conflicts=\(summary.conflictKeepExisting) skipped=\(summary.skipped.values.reduce(0, +))",
            category: "HistorySync"
        )
        return .imported(summary, manifestPhase: manifestPhase)
    }

    private func connect(instanceName: String) async throws -> NWConnection {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let endpoint = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<NWEndpoint, Error>) in
            let flag = ResumeOnce()
            let browser = NWBrowser(for: .bonjour(type: NearbyTransferService.serviceType, domain: nil), using: params)
            self.browser = browser
            browser.browseResultsChangedHandler = { results, _ in
                guard !flag.done else { return }
                if let match = results.first(where: {
                    if case .service(let name, _, _, _) = $0.endpoint { return name == instanceName }
                    return false
                }) {
                    flag.done = true
                    cont.resume(returning: match.endpoint)
                }
            }
            browser.stateUpdateHandler = { state in
                guard !flag.done else { return }
                switch state {
                case .failed(let error):
                    flag.done = true
                    cont.resume(throwing: error)
                case .cancelled:
                    flag.done = true
                    cont.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            browser.start(queue: queue)
        }
        browser?.cancel()
        browser = nil
        let conn = NWConnection(to: endpoint, using: params)
        conn.start(queue: queue)
        try await waitForReady(conn)
        return conn
    }

    private func waitForReady(_ conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let flag = ResumeOnce()
            conn.stateUpdateHandler = { state in
                guard !flag.done else { return }
                switch state {
                case .ready:
                    flag.done = true; cont.resume()
                case .failed(let error):
                    flag.done = true; cont.resume(throwing: error)
                case .cancelled:
                    flag.done = true; cont.resume(throwing: CancellationError())
                default: break
                }
            }
        }
    }
}
