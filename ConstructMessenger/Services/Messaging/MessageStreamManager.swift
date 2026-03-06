//
//  MessageStreamManager.swift
//  Construct Messenger
//
//  Replaces LongPollingManager — uses gRPC bidirectional MessageStream
//  for real-time message delivery with auto-reconnect and heartbeat.
//

import Foundation
import UIKit
import GRPCCore
import GRPCNIOTransportHTTP2

/// Manages bidirectional gRPC MessageStream for real-time messaging

// MARK: - Stream Event

private enum StreamEvent: Sendable {
    case message(ChatMessage)
    case deliveryReceipt([String])    // message IDs confirmed delivered to recipient
    case keySyncRequest(String)       // server-triggered X3DH re-init for userId
    case heartbeat                    // server heartbeat ack
}

@MainActor
@Observable
final class MessageStreamManager {

    static let shared = MessageStreamManager()

    // MARK: - State

    private(set) var isConnected = false
    /// Set to the current time whenever a heartbeat ack is received from the server.
    private(set) var lastHeartbeatDate: Date?

    // MARK: - Callbacks

    private var onMessageReceived: ((ChatMessage) -> Void)?
    /// Called when a DeliveryReceipt arrives from the server.
    /// Provides the IDs of messages confirmed delivered to the recipient.
    var onDeliveryReceipt: (([String]) -> Void)?
    /// Called when server sends KEY_SYNC (contentType=22) — triggers X3DH re-init for userId.
    var onKeySyncReceived: ((String) -> Void)?

    // MARK: - Private State

    private var streamTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var serverChangedObserver: NSObjectProtocol?
    private var retryCount = 0
    private let maxRetryDelay: TimeInterval = 60
    private(set) var isPaused = false
    private(set) var subscriptionUserIds: [String] = []
    private var lastPendingCursor: String = UserDefaults.standard.string(forKey: "construct.pendingCursor") ?? "" {
        didSet {
            UserDefaults.standard.set(lastPendingCursor, forKey: "construct.pendingCursor")
        }
    }

    /// Continuation for sending messages into the stream
    private var outboundContinuation: AsyncStream<Shared_Proto_Services_V1_MessageStreamRequest>.Continuation?

    // MARK: - Configuration

    private let heartbeatInterval: TimeInterval = 25

    // MARK: - Public API

    func connect(contactUserIds: [String] = [], onMessageReceived: @escaping (ChatMessage) -> Void) {
        self.onMessageReceived = onMessageReceived

        let subscriptionChanged = contactUserIds != subscriptionUserIds

        // If subscriptions changed and a loop is running, force reconnect so the
        // new contact's conversation ID is included in the subscribe request.
        if subscriptionChanged && (isConnected || streamTask != nil) {
            Log.info("📡 Subscriptions changed (\(subscriptionUserIds.count)→\(contactUserIds.count)) — reconnecting stream", category: "MessageStream")
            forceDisconnect()
        }

        self.subscriptionUserIds = contactUserIds
        isPaused = false

        // Already fully connected with up-to-date subscriptions.
        guard !isConnected else {
            Log.info("📡 MessageStream already connected", category: "MessageStream")
            return
        }

        // connectLoop is already running (in backoff between retries) — don't stack tasks.
        guard streamTask == nil else {
            Log.info("📡 MessageStream already reconnecting", category: "MessageStream")
            return
        }

        // Reconnect when server config changes
        if serverChangedObserver == nil {
            serverChangedObserver = NotificationCenter.default.addObserver(
                forName: .grpcServerChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                Log.info("🔄 gRPC server changed — reconnecting stream", category: "MessageStream")
                Task { @MainActor in
                    let ids = self.subscriptionUserIds
                    let cb = self.onMessageReceived
                    self.forceDisconnect()
                    if let cb { self.connect(contactUserIds: ids, onMessageReceived: cb) }
                }
            }
        }

        Log.info("📡 Starting MessageStream connection (subscribed to \(contactUserIds.count) contacts)", category: "MessageStream")
        ConnectionStatusManager.shared.markConnecting()
        streamTask = Task { [weak self] in
            await self?.connectLoop()
        }
    }

    /// Cancel any in-progress backoff/connection and start fresh immediately.
    /// Use when returning from background or recovering from a known-bad state.
    func forceReconnect(contactUserIds: [String], onMessageReceived: @escaping (ChatMessage) -> Void) {
        Log.info("🔁 Force reconnecting stream", category: "MessageStream")
        // Cancel current task even if it's sleeping in backoff
        streamTask?.cancel()
        streamTask = nil
        isConnected = false
        outboundContinuation?.finish()
        outboundContinuation = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        retryCount = 0
        connect(contactUserIds: contactUserIds, onMessageReceived: onMessageReceived)
    }

    func disconnect() {
        if let obs = serverChangedObserver {
            NotificationCenter.default.removeObserver(obs)
            serverChangedObserver = nil
        }
        forceDisconnect()
    }

    /// Disconnect without removing the server-change observer (used for reconnects).
    private func forceDisconnect() {
        isConnected = false
        outboundContinuation?.finish()
        outboundContinuation = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        streamTask?.cancel()
        streamTask = nil
        retryCount = 0
        ConnectionStatusManager.shared.markStreamDisconnected()
        Log.info("📡 MessageStream disconnected", category: "MessageStream")
    }

    func pause() {
        guard !isPaused else { return }
        isPaused = true
        disconnect()
        Log.info("📱 MessageStream paused", category: "MessageStream")
    }

    func resume(onMessageReceived: @escaping (ChatMessage) -> Void) {
        guard isPaused else { return }
        isPaused = false
        Log.info("📱 MessageStream resuming", category: "MessageStream")
        connect(onMessageReceived: onMessageReceived)
    }

    // MARK: - Send via Stream

    func sendHeartbeat() {
        var hb = Shared_Proto_Services_V1_Heartbeat()
        hb.timestamp = Int64(Date().timeIntervalSince1970)
        var req = Shared_Proto_Services_V1_MessageStreamRequest()
        req.request = .heartbeat(hb)
        outboundContinuation?.yield(req)
    }

    /// Send a delivery receipt for one or more messages via the live stream.
    /// - Parameters:
    ///   - messageIds: IDs of messages being acknowledged.
    ///   - recipientUserId: The original message sender — server uses this to route the receipt back without a DB lookup.
    ///   - status: `.delivered` after successful decrypt, `.failed` on unrecoverable decrypt error.
    func sendReceipt(_ messageIds: [String], to recipientUserId: String = "", status: Shared_Proto_Signaling_V1_ReceiptStatus) {
        guard !messageIds.isEmpty else { return }
        var direct = Shared_Proto_Signaling_V1_DirectReceipt()
        direct.messageIds = messageIds
        direct.status = status
        direct.timestamp = Int64(Date().timeIntervalSince1970)
        direct.senderDeviceID = KeychainManager.shared.loadDeviceID() ?? ""
        direct.recipientUserID = recipientUserId

        var delivery = Shared_Proto_Signaling_V1_DeliveryReceipt()
        delivery.direct = direct

        var req = Shared_Proto_Services_V1_MessageStreamRequest()
        req.receipt = delivery
        outboundContinuation?.yield(req)
        Log.info("📨 Receipt sent: \(status) for \(messageIds.count) msg(s) → recipient=\(recipientUserId.prefix(8))…", category: "MessageStream")
    }

    // MARK: - Private: Connection Loop

    private func connectLoop() async {
        let host = GRPCChannelManager.shared.currentHost
        let port = GRPCChannelManager.shared.currentPort
        Log.info("🔄 MessageStream connectLoop started → \(host):\(port)", category: "MessageStream")

        while !Task.isCancelled {
            // Fetch any messages that arrived while we were disconnected.
            // Done at the top of the loop so it always runs from the current
            // (non-cancelled) task, before each connection attempt.
            await fetchMissedMessages()

            guard !Task.isCancelled else { break }

            ConnectionStatusManager.shared.markConnecting()
            do {
                try await openStream()
                // Stream ended cleanly — brief pause before reconnecting to avoid tight loop
                // (e.g. server closes stream when 0 topics are subscribed)
                Log.info("📡 MessageStream ended cleanly, reconnecting in 3s", category: "MessageStream")
                retryCount = 0
                try await Task.sleep(for: .seconds(3))
            } catch is CancellationError {
                Log.info("🛑 MessageStream cancelled — connectLoop exiting", category: "MessageStream")
                break
            } catch {
                guard !Task.isCancelled else { break }
                // Log full error details for diagnosis
                if let rpcError = error as? RPCError {
                    Log.error("""
                        ❌ MessageStream RPC error:
                           code    = \(rpcError.code)
                           message = \(rpcError.message)
                           host    = \(host):\(port)
                           attempt = #\(retryCount + 1)
                        """, category: "MessageStream")
                } else {
                    Log.error("❌ MessageStream error (attempt #\(retryCount + 1)): \(error)", category: "MessageStream")
                }
                ConnectionStatusManager.shared.markStreamDisconnected(error: error.localizedDescription)
            }

            guard !Task.isCancelled else { break }

            // Exponential backoff with jitter
            retryCount += 1
            let base: TimeInterval = 2
            let delay = min(base * pow(2, Double(min(retryCount - 1, 5))), maxRetryDelay)
            let jitter = Double.random(in: 0...(delay * 0.25))
            let totalDelay = delay + jitter

            Log.info("⏳ MessageStream reconnecting in \(String(format: "%.1f", totalDelay))s (attempt #\(retryCount)) → \(host):\(port)", category: "MessageStream")
            do {
                try await Task.sleep(for: .seconds(totalDelay))
            } catch {
                // Task was cancelled during backoff sleep — exit immediately
                break
            }
        }
        Log.info("🏁 MessageStream connectLoop finished", category: "MessageStream")
    }

    private func fetchMissedMessages() async {
        do {
            let cursor = lastPendingCursor.isEmpty ? nil : lastPendingCursor
            Log.debug("🔍 fetchMissedMessages cursor=\(cursor ?? "nil")", category: "MessageStream")
            let result = try await MessagingServiceClient.shared.getPendingMessages(sinceCursor: cursor)
            if !result.messages.isEmpty {
                Log.info("📨 Fetched \(result.messages.count) missed message(s) after reconnect", category: "MessageStream")
                for msg in result.messages {
                    onMessageReceived?(msg)
                }
            } else {
                Log.debug("📭 fetchMissedMessages: no pending messages", category: "MessageStream")
            }
            if !result.nextCursor.isEmpty {
                lastPendingCursor = result.nextCursor
            }
        } catch is CancellationError {
            // Task was cancelled during force-reconnect or backgrounding — expected, no log needed
        } catch {
            if let rpcError = error as? RPCError {
                Log.error("⚠️ fetchMissedMessages RPC error: code=\(rpcError.code) message=\"\(rpcError.message)\"", category: "MessageStream")
            } else {
                Log.debug("fetchMissedMessages failed: \(error)", category: "MessageStream")
            }
        }
    }

    private func openStream() async throws {
        let host = GRPCChannelManager.shared.currentHost
        let port = GRPCChannelManager.shared.currentPort
        Log.info("📡 openStream → \(host):\(port) subscriptions=[\(subscriptionUserIds.joined(separator: ", "))]", category: "MessageStream")

        let grpcClient = try GRPCChannelManager.shared.makeClient()
        let msgClient = Shared_Proto_Services_V1_MessagingService.Client(wrapping: grpcClient)

        // Create outbound stream
        let (outboundStream, continuation) = AsyncStream<Shared_Proto_Services_V1_MessageStreamRequest>.makeStream()
        self.outboundContinuation = continuation
        self.isConnected = true
        Log.info("⏳ MessageStream opening to \(host):\(port)", category: "MessageStream")

        // Send initial subscribe
        var subscribeReq = Shared_Proto_Services_V1_MessageStreamRequest()
        var subscribe = Shared_Proto_Services_V1_SubscribeRequest()
        subscribe.conversationIds = subscriptionUserIds
        subscribe.includePresence = true
        subscribeReq.request = .subscribe(subscribe)
        continuation.yield(subscribeReq)
        Log.debug("📤 MessageStream subscribe sent: \(subscriptionUserIds.count) conversation(s)", category: "MessageStream")

        // Start heartbeat
        let hbInterval = self.heartbeatInterval
        let hbTask = Task { [weak self] () -> Void in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(hbInterval))
                await MainActor.run { self?.sendHeartbeat() }
            }
        }
        self.heartbeatTask = hbTask

        let request = StreamingClientRequest<Shared_Proto_Services_V1_MessageStreamRequest>(
            metadata: [],
            producer: { writer in
                for await msg in outboundStream {
                    try await writer.write(msg)
                }
            }
        )

        // Run client connections in background
        let connectTask = Task { try await grpcClient.runConnections() }

        defer {
            hbTask.cancel()
            connectTask.cancel()
            grpcClient.beginGracefulShutdown()
            self.isConnected = false
            self.outboundContinuation = nil
            Log.info("🔌 MessageStream disconnected from \(host):\(port)", category: "MessageStream")
        }

        // Use an async stream to bridge responses back to MainActor
        let (incomingStream, incomingContinuation) = AsyncStream<StreamEvent>.makeStream()

        // Process incoming events on MainActor
        let processingTask = Task { [weak self] in
            for await event in incomingStream {
                switch event {
                case .message(let msg):
                    Log.debug("📩 MessageStream received message from=\(msg.from) id=\(msg.id)", category: "MessageStream")
                    self?.onMessageReceived?(msg)
                case .deliveryReceipt(let ids):
                    Log.info("📬 MessageStream receipt: \(ids.count) message(s) delivered → \(ids.joined(separator: ", "))", category: "MessageStream")
                    self?.onDeliveryReceipt?(ids)
                case .keySyncRequest(let userId):
                    Log.info("🔑 KEY_SYNC received — re-keying session for \(userId.prefix(8))…", category: "MessageStream")
                    self?.onKeySyncReceived?(userId)
                case .heartbeat:
                    self?.lastHeartbeatDate = Date()
                }
            }
        }

        defer { processingTask.cancel() }

        try await runMessageStream(
            client: msgClient,
            request: request,
            incomingContinuation: incomingContinuation
        )
    }

    private nonisolated func runMessageStream(
        client: Shared_Proto_Services_V1_MessagingService.Client<HTTP2ClientTransport.Posix>,
        request: StreamingClientRequest<Shared_Proto_Services_V1_MessageStreamRequest>,
        incomingContinuation: AsyncStream<StreamEvent>.Continuation
    ) async throws {
        try await client.messageStream(
            request: request,
            onResponse: { (response: StreamingClientResponse<Shared_Proto_Services_V1_MessageStreamResponse>) async throws -> Void in
                let contents: StreamingClientResponse<Shared_Proto_Services_V1_MessageStreamResponse>.Contents
                switch response.accepted {
                case .success(let c):
                    Task { @MainActor in
                        ConnectionStatusManager.shared.markStreamConnected()
                        Log.info("✅ MessageStream RPC accepted — stream connected", category: "MessageStream")
                    }
                    contents = c
                case .failure(let error):
                    incomingContinuation.finish()
                    throw error
                }

                for try await part in contents.bodyParts {
                    switch part {
                    case .message(let streamResponse):
                        if let msg = MessageStreamManager.convertStreamResponse(streamResponse) {
                            incomingContinuation.yield(msg)
                        }
                    case .trailingMetadata:
                        break
                    }
                }
                incomingContinuation.finish()
            }
        )
    }

    // MARK: - Convert Response (nonisolated)

    private nonisolated static func convertStreamResponse(
        _ response: Shared_Proto_Services_V1_MessageStreamResponse
    ) -> StreamEvent? {
        switch response.response {
        case .message(let envelope):
            // KEY_SYNC: server-triggered re-key signal — no encrypted payload, route directly
            if envelope.contentType == .keySync {
                Log.info("🔑 KEY_SYNC envelope from \(envelope.sender.userID.prefix(8))…", category: "MessageStream")
                return .keySyncRequest(envelope.sender.userID)
            }
            // Unpack wire payload blob into crypto components
            guard let decoded = try? WirePayloadCoder.decode(envelope.encryptedPayload) else {
                Log.info("⚠️ Failed to decode encrypted_payload for message \(envelope.messageID)", category: "MessageStream")
                return nil
            }
            return .message(ChatMessage(
                id: envelope.messageID,
                from: envelope.sender.userID,
                to: envelope.recipient.userID,
                messageType: envelope.contentType == .sessionReset ? "CONTROL_MESSAGE" : "DIRECT_MESSAGE",
                ephemeralPublicKey: Data(decoded.ephemeralPublicKey),
                messageNumber: decoded.messageNumber,
                content: decoded.content,
                suiteId: 1,
                timestamp: UInt64(envelope.timestamp),
                oneTimePreKeyId: decoded.oneTimePreKeyId
            ))
        case .receipt(let receipt):
            // Deliver receipt: extract confirmed message IDs and propagate
            if case .direct(let directReceipt) = receipt.receiptType,
               directReceipt.status == .delivered,
               !directReceipt.messageIds.isEmpty {
                return .deliveryReceipt(directReceipt.messageIds)
            }
            return nil
        case .typing(let indicator):
            Log.debug("✍️ Typing: \(indicator.userID) in \(indicator.conversationID)", category: "MessageStream")
            return nil
        case .ack(let ack):
            Log.debug("✅ Message ack: \(ack.messageID)", category: "MessageStream")
            return nil
        case .error(let error):
            Log.error("❌ Stream error: \(error.errorCode) - \(error.errorMessage)", category: "MessageStream")
            return nil
        case .presence(let update):
            Log.debug("👤 Presence: \(update.userID)", category: "MessageStream")
            return nil
        case .heartbeatAck(let ack):
            Log.debug("💓 Heartbeat ack: server=\(ack.serverTimestamp)", category: "MessageStream")
            Task { @MainActor in
                ConnectionStatusManager.shared.markStreamConnected()
            }
            return .heartbeat
        case .none:
            return nil
        }
    }
}
