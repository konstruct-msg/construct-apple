//
//  NearbyTransferService.swift
//  Construct Messenger
//
//  Reusable P2P transfer engine over local WiFi / WiFi Direct.
//  Used for: local backup transfer (now) and device history sync (future).
//
//  Security:
//    — PIN-based pairing: 6-digit code displayed on sender, entered on receiver.
//      Instance name = SHA256("ctt1_instance:<pin>")[0:16] so receiver finds the
//      right sender without leaking the PIN via mDNS.
//    — ECDH (Curve25519) forward-secret channel key, derived with HKDF-SHA256.
//    — PIN authentication: both sides prove knowledge of PIN via HMAC-SHA256.
//    — Payload encrypted in 64 KB chunks with ChaChaPoly (counter nonce).
//
//  Wire protocol (CTT1):
//    S→R  [4] "CTT1"  [1] 0x01 (version)  [32] senderPub  [1] transferType  [8 LE] payloadLength
//    R→S  [32] receiverPub  [32] HMAC_R   (HMAC over senderPub+receiverPub+"R")
//    S→R  [1]  0x01 (OK)   [32] HMAC_S   (HMAC over receiverPub+senderPub+"S")
//    S→R  chunks: [4 LE] sealedLen + ChaChaPoly.combined(chunk, nonce=counter)
//    S→R  [4 LE] 0x00000000 (EOF)
//
//  Reuse in Device History Sync (future):
//    payload = LocalBackupService.buildTransferPayload(context:)   (same binary format)
//    type    = TransferType.historySync
//    receive: LocalBackupService.stageTransferPayload(receivedPayload) — identical flow
//

import Foundation
import Network
import CryptoKit

// MARK: - Errors

enum NearbyTransferError: LocalizedError {
    case authenticationFailed
    case connectionClosed
    case malformedFrame
    case transferCancelled

    var errorDescription: String? {
        switch self {
        case .authenticationFailed: return NSLocalizedString("transfer_error_auth", comment: "")
        case .connectionClosed:     return NSLocalizedString("transfer_error_connection", comment: "")
        case .malformedFrame:       return NSLocalizedString("transfer_error_corrupt", comment: "")
        case .transferCancelled:    return NSLocalizedString("transfer_error_cancelled", comment: "")
        }
    }
}

// MARK: - Service

@MainActor
@Observable
final class NearbyTransferService {

    // MARK: - Types

    enum TransferState: Equatable {
        case idle
        case preparing
        case advertising    // sender: showing PIN, waiting for connection
        case browsing       // receiver: searching for sender
        case handshaking
        case transferring
        case complete
        case failed(String)

        static func == (lhs: TransferState, rhs: TransferState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.preparing, .preparing), (.advertising, .advertising),
                 (.browsing, .browsing), (.handshaking, .handshaking),
                 (.transferring, .transferring), (.complete, .complete): return true
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
    }

    enum TransferType: UInt8 {
        case backup      = 0x01  // .ctbackup payload (Core Data + MessageKeyStore)
        case historySync = 0x02  // future: same payload, additive intent
    }

    // MARK: - Observable State

    var transferState: TransferState = .idle
    var pin: String = ""
    var progress: Double = 0.0
    var receivedPayload: Data?
    var receivedType: TransferType?

    // MARK: - Private

    private let serviceType = "_construct-transfer._tcp"
    private let queue = DispatchQueue(label: "com.construct.transfer", qos: .userInitiated)
    private let chunkSize = 65_536

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var transferTask: Task<Void, Never>?

    // MARK: - Public API

    func startSending(payload: Data, type: TransferType) {
        guard case .idle = transferState else { return }
        transferState = .preparing
        progress = 0
        let generatedPIN = generatePIN()
        pin = generatedPIN

        transferTask = Task {
            do {
                try await runSender(payload: payload, type: type, pin: generatedPIN)
                transferState = .complete
            } catch is CancellationError {
                // cancel() already reset state
            } catch {
                if !Task.isCancelled {
                    transferState = .failed(error.localizedDescription)
                }
            }
        }
    }

    func startReceiving(pin: String) {
        guard case .idle = transferState else { return }
        transferState = .browsing
        progress = 0
        let trimmedPIN = pin.trimmingCharacters(in: .whitespaces)

        transferTask = Task {
            do {
                let (data, type) = try await runReceiver(pin: trimmedPIN)
                receivedPayload = data
                receivedType = type
                transferState = .complete
            } catch is CancellationError {
                // cancel() already reset state
            } catch {
                if !Task.isCancelled {
                    transferState = .failed(error.localizedDescription)
                }
            }
        }
    }

    func cancel() {
        transferTask?.cancel()
        transferTask = nil
        listener?.cancel()
        browser?.cancel()
        connection?.cancel()
        listener = nil
        browser = nil
        connection = nil
        pin = ""
        progress = 0
        transferState = .idle
    }

    func reset() {
        cancel()
        receivedPayload = nil
        receivedType = nil
    }

    // MARK: - Sender Pipeline

    private func runSender(payload: Data, type: TransferType, pin: String) async throws {
        let myKey = Curve25519.KeyAgreement.PrivateKey()
        let instanceName = instanceName(for: pin)

        let params = makeTCPParams()
        let listener = try NWListener(using: params)
        listener.service = NWListener.Service(name: instanceName, type: serviceType)
        self.listener = listener

        // Start listener and wait for an incoming connection.
        // stateUpdateHandler handles .ready (→ .advertising) and errors.
        // newConnectionHandler resolves the continuation on the first connection.
        let conn = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<NWConnection, Error>) in
            let flag = ResumeOnce()

            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    Task { @MainActor in self?.transferState = .advertising }
                case .failed(let error):
                    guard !flag.done else { return }
                    flag.done = true
                    cont.resume(throwing: error)
                case .cancelled:
                    guard !flag.done else { return }
                    flag.done = true
                    cont.resume(throwing: CancellationError())
                default: break
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
        connection = conn
        transferState = .handshaking

        conn.start(queue: queue)
        try await waitForReady(conn)

        let sessionKey = try await senderHandshake(
            conn: conn, myKey: myKey, pin: pin, type: type, payloadLength: payload.count
        )
        transferState = .transferring
        try await streamPayload(conn: conn, payload: payload, key: sessionKey)
    }

    // MARK: - Receiver Pipeline

    private func runReceiver(pin: String) async throws -> (Data, TransferType) {
        let instanceName = instanceName(for: pin)
        let params = makeTCPParams()

        // Browse for the sender's Bonjour service.
        let endpoint = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<NWEndpoint, Error>) in
            let flag = ResumeOnce()
            let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: params)
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
                if case .failed(let error) = state, !flag.done {
                    flag.done = true
                    cont.resume(throwing: error)
                }
            }
            browser.start(queue: queue)
        }

        browser?.cancel()
        browser = nil

        transferState = .handshaking

        let conn = NWConnection(to: endpoint, using: params)
        connection = conn
        conn.start(queue: queue)
        try await waitForReady(conn)

        let (sessionKey, type, payloadLength) = try await receiverHandshake(conn: conn, pin: pin)
        transferState = .transferring

        let data = try await receivePayload(conn: conn, key: sessionKey, expectedLength: payloadLength)
        return (data, type)
    }

    // MARK: - Sender Handshake

    private func senderHandshake(
        conn: NWConnection,
        myKey: Curve25519.KeyAgreement.PrivateKey,
        pin: String,
        type: TransferType,
        payloadLength: Int
    ) async throws -> SymmetricKey {
        let myPub = myKey.publicKey.rawRepresentation  // 32 bytes

        // Send initial frame
        var frame = Data("CTT1".utf8)
        frame.append(0x01)                              // version
        frame.append(myPub)                             // 32 bytes sender pub
        frame.append(type.rawValue)                     // 1 byte type
        frame.append(contentsOf: uint64LE(payloadLength))  // 8 bytes LE
        try await sendData(conn, data: frame)

        // Receive: [32] receiverPub + [32] HMAC_R
        let authBytes = try await receiveExact(conn, length: 64)
        let receiverPub  = Data(authBytes[0..<32])
        let receiverHMAC = Data(authBytes[32..<64])

        // Verify receiver authentication
        guard receiverHMAC == authHMAC(pin: pin, first: myPub, second: receiverPub, role: "R") else {
            try? await sendData(conn, data: Data([0x00]))
            throw NearbyTransferError.authenticationFailed
        }

        let sessionKey = try deriveSessionKey(myPrivate: myKey, theirPublic: receiverPub)

        // Send ACK + HMAC_S
        var ack = Data([0x01])
        ack.append(authHMAC(pin: pin, first: receiverPub, second: myPub, role: "S"))
        try await sendData(conn, data: ack)

        return sessionKey
    }

    // MARK: - Receiver Handshake

    private func receiverHandshake(conn: NWConnection, pin: String) async throws -> (SymmetricKey, TransferType, Int) {
        // Receive: [4]"CTT1" + [1]version + [32]senderPub + [1]type + [8]payloadLen = 46 bytes
        let frame = try await receiveExact(conn, length: 46)
        guard Data(frame[0..<4]) == Data("CTT1".utf8) else { throw NearbyTransferError.malformedFrame }
        let senderPub     = Data(frame[5..<37])
        let typeRaw       = frame[37]
        let payloadLength = Int(UInt64(littleEndian: frame[38..<46].withUnsafeBytes { $0.load(as: UInt64.self) }))

        guard let type = TransferType(rawValue: typeRaw) else { throw NearbyTransferError.malformedFrame }

        let myKey = Curve25519.KeyAgreement.PrivateKey()
        let myPub = myKey.publicKey.rawRepresentation

        // Send: [32] myPub + [32] HMAC_R
        var authFrame = myPub
        authFrame.append(authHMAC(pin: pin, first: senderPub, second: myPub, role: "R"))
        try await sendData(conn, data: authFrame)

        // Receive: [1] ok + [32] HMAC_S
        let ackBytes = try await receiveExact(conn, length: 33)
        guard ackBytes[0] == 0x01 else { throw NearbyTransferError.authenticationFailed }
        let senderHMAC = Data(ackBytes[1..<33])

        guard senderHMAC == authHMAC(pin: pin, first: myPub, second: senderPub, role: "S") else {
            throw NearbyTransferError.authenticationFailed
        }

        let sessionKey = try deriveSessionKey(myPrivate: myKey, theirPublic: senderPub)
        return (sessionKey, type, payloadLength)
    }

    // MARK: - Streaming

    private func streamPayload(conn: NWConnection, payload: Data, key: SymmetricKey) async throws {
        var offset = 0
        var chunkIndex: UInt32 = 0
        let total = payload.count

        while offset < total {
            try Task.checkCancellation()
            let end = min(offset + chunkSize, total)
            let chunk = Data(payload[offset..<end])
            let sealed = try ChaChaPoly.seal(chunk, using: key, nonce: makeNonce(chunkIndex))
            var frame = uint32LE(UInt32(sealed.combined.count))
            frame.append(sealed.combined)
            try await sendData(conn, data: frame)
            offset = end
            chunkIndex += 1
            progress = Double(offset) / Double(total)
        }

        try await sendData(conn, data: uint32LE(0))  // EOF sentinel
    }

    private func receivePayload(conn: NWConnection, key: SymmetricKey, expectedLength: Int) async throws -> Data {
        var result = Data()
        if expectedLength > 0 { result.reserveCapacity(expectedLength) }
        var chunkIndex: UInt32 = 0

        while true {
            try Task.checkCancellation()
            let lenBytes = try await receiveExact(conn, length: 4)
            let len = Int(UInt32(littleEndian: lenBytes.withUnsafeBytes { $0.load(as: UInt32.self) }))
            if len == 0 { break }  // EOF sentinel

            let combined = try await receiveExact(conn, length: len)
            let box   = try ChaChaPoly.SealedBox(combined: combined)
            let chunk = try ChaChaPoly.open(box, using: key)
            result.append(chunk)
            chunkIndex += 1
            progress = expectedLength > 0 ? Double(result.count) / Double(expectedLength) : 0
        }

        return result
    }

    // MARK: - Network Helpers

    private func waitForReady(_ conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let flag = ResumeOnce()
            let existing = conn.stateUpdateHandler
            conn.stateUpdateHandler = { state in
                existing?(state)
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

    private func sendData(_ conn: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume() }
            })
        }
    }

    private func receiveExact(_ conn: NWConnection, length: Int) async throws -> Data {
        var buffer = Data()
        while buffer.count < length {
            let remaining = length - buffer.count
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

    // MARK: - Crypto Helpers

    private func deriveSessionKey(
        myPrivate: Curve25519.KeyAgreement.PrivateKey,
        theirPublic pubData: Data
    ) throws -> SymmetricKey {
        let theirKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: pubData)
        let shared   = try myPrivate.sharedSecretFromKeyAgreement(with: theirKey)
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("ctt1_session_v1".utf8),
            sharedInfo: Data(),
            outputByteCount: 32
        )
    }

    private func authHMAC(pin: String, first: Data, second: Data, role: String) -> Data {
        let keyData = Data(SHA256.hash(data: Data("ctt1_auth_v1:\(pin)".utf8)))
        let key     = SymmetricKey(data: keyData)
        let message = first + second + Data(role.utf8)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
    }

    private func makeNonce(_ index: UInt32) -> ChaChaPoly.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        withUnsafeBytes(of: index.littleEndian) { src in
            bytes[0] = src[0]; bytes[1] = src[1]
            bytes[2] = src[2]; bytes[3] = src[3]
        }
        return try! ChaChaPoly.Nonce(data: Data(bytes))
    }

    // MARK: - Utilities

    private func generatePIN() -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, 4, &bytes)
        let raw = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8)
                | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
        return String(format: "%06d", Int(raw) % 1_000_000)
    }

    private func instanceName(for pin: String) -> String {
        let hash = SHA256.hash(data: Data("ctt1_instance:\(pin)".utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    private func makeTCPParams() -> NWParameters {
        let p = NWParameters.tcp
        p.includePeerToPeer = true
        return p
    }

    private func uint64LE(_ value: Int) -> Data {
        var le = UInt64(value).littleEndian
        return Data(bytes: &le, count: 8)
    }

    private func uint32LE(_ value: UInt32) -> Data {
        var le = value.littleEndian
        return Data(bytes: &le, count: 4)
    }
}

/// Thread-safe one-shot flag for guarding continuation resumes.
/// All NW callbacks are serialized on the same DispatchQueue, so this
/// @unchecked Sendable wrapper is safe.
private final class ResumeOnce: @unchecked Sendable {
    var done = false
}
