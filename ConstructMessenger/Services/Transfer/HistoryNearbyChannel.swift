//
//  HistoryNearbyChannel.swift
//  Construct Messenger
//
//  CTT1 v2 over the same Bonjour/TCP pipe the v1 backup uses. One connection per phase (K18):
//  the offering device advertises, sends the opening, reads the reply, streams CTH1; the new
//  device browses, verifies, replies, imports as records arrive. The frames, the checks and the
//  chunk stream are the core's (`HistorySender` / `HistoryReceiver`); the directory lookups are
//  HistoryChannel's. This file only moves bytes and orders the calls. No PIN: the discovery tag
//  is scope, the hybrid signatures and the QR pin are the authentication.
//

import CoreData
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
    ) async throws -> HistoryPeer {
        var lastError: Error = HistoryChannelError.peerNotInDirectory
        for attempt in 1...peerKeysAttempts {
            try Task.checkCancellation()
            do {
                return try await HistoryChannel.fetchPeerKeys(
                    ownUserId: ownUserId,
                    peerDeviceId: peerDeviceId,
                    pinnedIdentity: pinnedIdentity
                )
            } catch HistoryError.QrPinMismatch(let message) {
                throw HistoryError.QrPinMismatch(message: message) // a hard stop, never a retry
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
        peer: HistoryPeer,
        local: HistoryLocalKeys,
        coordinator: HistoryTransferCoordinator,
        context: NSManagedObjectContext
    ) async throws {
        let tag = historyDiscoveryTag(userIdDashed: local.userIdDashed, deviceIdHex: peer.deviceIdHex)
        let instanceName = historyDiscoveryInstanceName(tag: tag)
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
        peer: HistoryPeer,
        local: HistoryLocalKeys,
        coordinator: HistoryTransferCoordinator,
        context: NSManagedObjectContext
    ) async throws {
        let sender = try CryptoManager.shared.historyCore().historyOfferNearby(
            userId: local.userIdRaw,
            peer: peer.coreKeys,
            skip: kind == .skip,
            // The Flow B pin was checked against the directory when `peer` was fetched; the
            // reply is then checked against `peer`, so it is pinned too.
            pinnedReceiverIdentity: nil
        )
        try await transport.send(sender.firstFrame())
        Log.info("history_opening_sent kind=\(kind) snapshot=\(HistorySnapshotIdentity.tag(sender.snapshotId())) to=\(peer.deviceIdHex.prefix(8))…", category: "HistorySync")
        if kind == .skip {
            coordinator.markSkipped()
            return
        }

        let reply = try await transport.receiveExact(Int(historyReplyLen()))
        do {
            try sender.acceptReply(reply: reply)
        } catch {
            Log.error("history_reply_refused reason=\(error.localizedDescription)", category: "HistorySync")
            throw error
        }

        let identity = HistorySnapshotIdentity.make(
            userId: local.userIdDashed,
            sourceDeviceId: local.deviceIdHex,
            snapshotId: sender.snapshotId()
        )
        // The encoder walks Core Data when the stream is created, so it runs on the context's
        // queue; media are references, read from disk as they are sent.
        let (items, counters) = await context.perform {
            let encoder = HistorySnapshotEncoder(identity: identity)
            let items = kind == .transcript
                ? encoder.encodeTranscript(context: context)
                : encoder.encodeMedia(context: context)
            return (items, encoder.counters)
        }
        switch kind {
        case .transcript:
            try await coordinator.sendTranscript(items: items, through: sender, over: transport)
        case .media:
            try await coordinator.sendMedia(items: items, through: sender, over: transport)
        case .skip:
            break
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
    typealias PeerResolver = @MainActor (_ deviceIdHex: String) async throws -> HistoryPeer

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
        let tag = historyDiscoveryTag(userIdDashed: local.userIdDashed, deviceIdHex: local.deviceIdHex)
        let instanceName = historyDiscoveryInstanceName(tag: tag)
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
        let receiver = try CryptoManager.shared.historyCore().historyReceive(userId: local.userIdRaw, fromFile: false)
        let outcome: HistoryCoreStream.Outcome
        do {
            outcome = try await coordinator.receive(
                from: HistoryTransportSource(transport),
                into: receiver,
                pin: pin,
                expectedUserId: local.userIdDashed,
                context: context,
                // The frame names the offering device; its keys come from our own account's
                // directory entry, never from the frame.
                resolve: { deviceIdHex in try await resolvePeer(deviceIdHex).knownKeys },
                reply: { try await transport.send($0) }
            )
        } catch {
            Log.error("history_receive_refused reason=\(error.localizedDescription)", category: "HistorySync")
            throw error
        }
        switch outcome {
        case .skipped:
            coordinator.markSkipped()
            return .skipped
        case .imported(let summary, let manifestPhase):
            Log.info(
                "history_snapshot_done source=nearby phase=\(manifestPhase) applied=\(summary.applied) conflicts=\(summary.conflictKeepExisting) skipped=\(summary.skipped.values.reduce(0, +))",
                category: "HistorySync"
            )
            NotificationCenter.default.post(name: .historyImported, object: nil)
            return .imported(summary, manifestPhase: manifestPhase)
        }
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
