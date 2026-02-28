//
//  MessageStreamManager.swift
//  Construct Messenger
//
//  Replaces LongPollingManager — uses gRPC bidirectional MessageStream
//  for real-time message delivery with auto-reconnect and heartbeat.
//

import Foundation
import Combine
import UIKit
import GRPCCore
import GRPCNIOTransportHTTP2

/// Manages bidirectional gRPC MessageStream for real-time messaging

@MainActor
final class MessageStreamManager: ObservableObject {

    // MARK: - Published State

    @Published private(set) var isConnected = false

    // MARK: - Callbacks

    private var onMessageReceived: ((ChatMessage) -> Void)?

    // MARK: - Private State

    private var streamTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var serverChangedObserver: NSObjectProtocol?
    private var retryCount = 0
    private let maxRetryDelay: TimeInterval = 60
    private var isPaused = false
    private var subscriptionUserIds: [String] = []
    private var lastPendingCursor: String = ""

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

    func disconnect() {
        if let obs = serverChangedObserver {
            NotificationCenter.default.removeObserver(obs)
            serverChangedObserver = nil
        }
        forceDisconnect()
    }

    /// Disconnect without removing the server-change observer (used for reconnects).
    private func forceDisconnect() {
        isPaused = false
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

    // MARK: - Private: Connection Loop

    private func connectLoop() async {
        while !Task.isCancelled {
            do {
                try await openStream()
                // Stream ended normally — reconnect
                retryCount = 0
            } catch is CancellationError {
                break
            } catch {
                guard !Task.isCancelled else { break }
                Log.error("❌ MessageStream error: \(error)", category: "MessageStream")
                ConnectionStatusManager.shared.markStreamDisconnected(error: error.localizedDescription)
            }

            guard !Task.isCancelled else { break }

            // Exponential backoff
            retryCount += 1
            let base: TimeInterval = 2
            let delay = min(base * pow(2, Double(min(retryCount - 1, 5))), maxRetryDelay)
            let jitter = Double.random(in: 0...(delay * 0.25))
            let totalDelay = delay + jitter

            Log.info("⏳ MessageStream reconnecting in \(String(format: "%.1f", totalDelay))s (attempt #\(retryCount))", category: "MessageStream")
            try? await Task.sleep(for: .seconds(totalDelay))
            await fetchMissedMessages()
        }
    }

    private func fetchMissedMessages() async {
        do {
            let cursor = lastPendingCursor.isEmpty ? nil : lastPendingCursor
            let result = try await MessagingServiceClient.shared.getPendingMessages(sinceCursor: cursor)
            if !result.messages.isEmpty {
                Log.info("📨 Fetched \(result.messages.count) missed message(s) after reconnect", category: "MessageStream")
                for msg in result.messages {
                    onMessageReceived?(msg)
                }
            }
            if !result.nextCursor.isEmpty {
                lastPendingCursor = result.nextCursor
            }
        } catch {
            Log.debug("⚠️ fetchMissedMessages failed: \(error)", category: "MessageStream")
        }
    }

    private func openStream() async throws {
        let grpcClient = try GRPCChannelManager.shared.makeClient()
        let msgClient = Shared_Proto_Services_V1_MessagingService.Client(wrapping: grpcClient)

        // Create outbound stream
        let (outboundStream, continuation) = AsyncStream<Shared_Proto_Services_V1_MessageStreamRequest>.makeStream()
        self.outboundContinuation = continuation
        self.isConnected = true
        ConnectionStatusManager.shared.markStreamConnected()

        // Send initial subscribe
        var subscribeReq = Shared_Proto_Services_V1_MessageStreamRequest()
        var subscribe = Shared_Proto_Services_V1_SubscribeRequest()
        subscribe.conversationIds = subscriptionUserIds
        subscribe.includePresence = true
        subscribeReq.request = .subscribe(subscribe)
        continuation.yield(subscribeReq)

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
        }

        // Use an async stream to bridge responses back to MainActor
        let (incomingStream, incomingContinuation) = AsyncStream<ChatMessage>.makeStream()

        // Process incoming messages on MainActor
        let processingTask = Task { [weak self] in
            for await msg in incomingStream {
                self?.onMessageReceived?(msg)
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
        incomingContinuation: AsyncStream<ChatMessage>.Continuation
    ) async throws {
        try await client.messageStream(
            request: request,
            onResponse: { (response: StreamingClientResponse<Shared_Proto_Services_V1_MessageStreamResponse>) async throws -> Void in
                let contents: StreamingClientResponse<Shared_Proto_Services_V1_MessageStreamResponse>.Contents
                switch response.accepted {
                case .success(let c):
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
    ) -> ChatMessage? {
        switch response.response {
        case .message(let envelope):
            // Unpack wire payload blob into crypto components
            guard let decoded = try? WirePayloadCoder.decode(envelope.encryptedPayload) else {
                Log.info("⚠️ Failed to decode encrypted_payload for message \(envelope.messageID)", category: "MessageStream")
                return nil
            }
            return ChatMessage(
                id: envelope.messageID,
                from: envelope.sender.userID,
                to: envelope.recipient.userID,
                messageType: envelope.contentType == .sessionReset ? "CONTROL_MESSAGE" : "DIRECT_MESSAGE",
                ephemeralPublicKey: Data(decoded.ephemeralPublicKey),
                messageNumber: decoded.messageNumber,
                content: decoded.content,
                suiteId: 1,
                timestamp: UInt64(envelope.timestamp)
            )
        case .receipt(let receipt):
            Log.debug("📬 Delivery receipt received", category: "MessageStream")
            _ = receipt
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
            Task { @MainActor in ConnectionStatusManager.shared.markStreamConnected() }
            return nil
        case .none:
            return nil
        }
    }
}
