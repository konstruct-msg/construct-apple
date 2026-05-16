/*
 * Copyright 2025, gRPC Authors All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#if canImport(Network)
import Network
import Foundation
import GRPCCore

/// A `ClientTransport` for gRPC over HTTP/3 on Darwin platforms (iOS 17+, macOS 14+).
///
/// Uses Apple's Network.framework QUIC implementation (`NWParameters.quic`) with
/// the `h3` ALPN token. Each gRPC call runs on a dedicated bidirectional QUIC stream;
/// the OS transparently coalesces multiple streams onto a single QUIC connection
/// (RFC 9000 § 9.2 connection coalescing).
///
/// This transport has no dependency on SwiftNIO — it uses only `GRPCCore` and
/// Apple's `Network.framework`.
///
/// ## Usage
///
/// ```swift
/// try await withThrowingDiscardingTaskGroup { group in
///   let transport = HTTP3ClientTransport(
///     host: "api.example.com",
///     port: 443
///   )
///   let client = GRPCClient(transport: transport)
///   group.addTask { try await client.run() }
///   // ... make calls
/// }
/// ```
struct HTTP3ClientTransport: ClientTransport {
  typealias Bytes = GRPCNetworkTransportBytes

  private let config: Config
  private let stateMachine: _TransportStateMachine

  var retryThrottle: RetryThrottle? { nil }

  // MARK: - Init

  /// Create a new HTTP/3 client transport.
  ///
  /// - Parameters:
  ///   - host: The server hostname (used for SNI and the `:authority` header).
  ///   - port: The server port (typically 443).
  ///   - config: Transport configuration.
  init(host: String, port: UInt16, config: Config = .defaults) {
    self.config = Config(host: host, port: port, other: config)
    self.stateMachine = _TransportStateMachine()
  }

  // MARK: - ClientTransport

  func connect() async throws {
    await stateMachine.markConnecting()
    // The transport is connectionless at this level — each stream establishes
    // its own QUIC stream on demand. This method just parks until graceful shutdown.
    await stateMachine.waitForShutdown()
  }

  func beginGracefulShutdown() {
    stateMachine.beginGracefulShutdown()
  }

  func withStream<T: Sendable>(
    descriptor: MethodDescriptor,
    options: CallOptions,
    _ closure: (_ stream: RPCStream<Inbound, Outbound>, _ context: ClientContext) async throws -> T
  ) async throws -> T {
    guard await stateMachine.canMakeStream() else {
      throw RPCError(code: .unavailable, message: "Transport is shut down.")
    }

    let quicStream = QUICStreamConnection(
      host: config.host,
      port: config.port,
      tlsOptions: config.tlsOptions
    )
    try await quicStream.establish()

    let h3Stream = HTTP3RequestStream(
      stream: quicStream,
      authority: config.host,
      methodPath: "/\(descriptor.fullyQualifiedMethod)"
    )

    // Bridge HTTP3RequestStream → RPCStream<Inbound, Outbound>
    let rpcStream = makeRPCStream(descriptor: descriptor, h3Stream: h3Stream)
    let context = ClientContext(
      descriptor: descriptor,
      remotePeer: "h3:\(config.host):\(config.port)",
      localPeer: "h3:local"
    )
    do {
      return try await closure(rpcStream, context)
    } catch {
      quicStream.cancel()
      throw error
    }
  }

  func config(forMethod descriptor: MethodDescriptor) -> MethodConfig? { nil }

  // MARK: - Private helpers

  private func makeRPCStream(
    descriptor: MethodDescriptor,
    h3Stream: HTTP3RequestStream
  ) -> RPCStream<Inbound, Outbound> {
    let (inboundStream, inboundContinuation) = AsyncThrowingStream<RPCResponsePart<Bytes>, any Error>.makeStream()
    let h3Writer = HTTP3Outbound(h3Stream: h3Stream, inboundContinuation: inboundContinuation)
    return RPCStream(
      descriptor: descriptor,
      inbound: RPCAsyncSequence(wrapping: inboundStream),
      outbound: RPCWriter<RPCRequestPart<Bytes>>.Closable(wrapping: h3Writer)
    )
  }
}

// MARK: - Outbound writer

private final class HTTP3Outbound: ClosableRPCWriterProtocol, @unchecked Sendable {
  typealias Element = RPCRequestPart<GRPCNetworkTransportBytes>

  private let h3Stream: HTTP3RequestStream
  private let inboundContinuation: AsyncThrowingStream<RPCResponsePart<GRPCNetworkTransportBytes>, any Error>.Continuation
  private var headersSent = false

  init(
    h3Stream: HTTP3RequestStream,
    inboundContinuation: AsyncThrowingStream<RPCResponsePart<GRPCNetworkTransportBytes>, any Error>.Continuation
  ) {
    self.h3Stream = h3Stream
    self.inboundContinuation = inboundContinuation
  }

  func write(contentsOf elements: some Sequence<RPCRequestPart<GRPCNetworkTransportBytes>>) async throws {
    for element in elements {
      try await write(element)
    }
  }

  func write(_ element: RPCRequestPart<GRPCNetworkTransportBytes>) async throws {
    switch element {
    case .metadata(let metadata):
      _ = metadata
      try await h3Stream.sendStreamingHeaders()
      headersSent = true
      let stream = h3Stream
      let cont = inboundContinuation
      Task {
        do {
          let initialMetadata: Metadata = [:]
          _ = try await stream.receiveResponse { message in
            if initialMetadata.isEmpty {
              cont.yield(.metadata(initialMetadata))
            }
            let bytes = GRPCNetworkTransportBytes(message)
            cont.yield(.message(bytes))
          }
          cont.yield(.status(Status(code: .ok, message: ""), [:]))
          cont.finish()
        } catch let error as RPCError {
          cont.yield(.status(Status(code: Status.Code(error.code), message: error.message), error.metadata))
          cont.finish()
        } catch {
          cont.finish(throwing: error)
        }
      }

    case .message(let bytes):
      try await h3Stream.sendMessage(Array(bytes.data))
    }
  }

  func finish() async {
    try? await h3Stream.finishSending()
  }

  func finish(throwing error: any Error) async {
    h3Stream.cancel()
    inboundContinuation.finish(throwing: error)
  }
}

// MARK: - State machine

/// Simple state machine for the transport lifecycle.
private final class _TransportStateMachine: @unchecked Sendable {
  private enum State { case idle, connecting, running, shuttingDown, done }
  private var state: State = .idle
  private let lock = NSLock()
  private var shutdownContinuation: CheckedContinuation<Void, Never>?

  func markConnecting() async {
    lock.withLock { state = .connecting }
  }

  func canMakeStream() async -> Bool {
    lock.withLock {
      switch state {
      case .idle, .connecting, .running: state = .running; return true
      default: return false
      }
    }
  }

  func beginGracefulShutdown() {
    let cont: CheckedContinuation<Void, Never>? = lock.withLock {
      state = .done
      return shutdownContinuation
    }
    cont?.resume()
  }

  func waitForShutdown() async {
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      let already: Bool = lock.withLock {
        if state == .done { return true }
        shutdownContinuation = cont
        return false
      }
      if already { cont.resume() }
    }
  }
}

// MARK: - Config

extension HTTP3ClientTransport {
  /// Configuration for `HTTP3ClientTransport`.
  struct Config: Sendable {
    /// The server hostname.
    var host: String
    /// The server port (typically 443).
    var port: UInt16
    /// TLS options applied to the QUIC connection.
    var tlsOptions: NWProtocolTLS.Options

    init(host: String, port: UInt16, tlsOptions: NWProtocolTLS.Options) {
      self.host = host
      self.port = port
      self.tlsOptions = tlsOptions
    }

    init(host: String, port: UInt16) {
      self.init(host: host, port: port, tlsOptions: NWProtocolTLS.Options())
    }

    /// Default configuration — TLS with system trust store.
    public static var defaults: Self {
      Self(host: "", port: 443)
    }

    fileprivate init(host: String, port: UInt16, other: Config) {
      self.host = host
      self.port = port
      self.tlsOptions = other.tlsOptions
    }
  }
}

// MARK: - Convenience init

extension HTTP3ClientTransport {
  init(host: String, port: UInt16, tlsOptions: NWProtocolTLS.Options) {
    self.init(host: host, port: port, config: Config(host: host, port: port, tlsOptions: tlsOptions))
  }
}
#endif
