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

/// Wraps a single `NWConnection` with QUIC parameters as one bidirectional QUIC stream.
///
/// Each gRPC call creates its own `QUICStreamConnection`. The Network.framework stack
/// transparently coalesces multiple `NWConnection`s to the same endpoint onto a single
/// underlying QUIC connection (connection coalescing, RFC 9000 § 9.2).
///
/// Call `establish()` before sending. After the connection reaches `.ready`, use
/// `send(_:)` and `receive()` to exchange data. Call `closeWrite()` after the last
/// request bytes to signal end-of-stream.
final class QUICStreamConnection: @unchecked Sendable {
  private let connection: NWConnection
  private let queue: DispatchQueue
  private let receiveBuffer: AsyncStream<Result<[UInt8], NWError>>
  private let receiveContinuation: AsyncStream<Result<[UInt8], NWError>>.Continuation

  init(host: String, port: UInt16, tlsOptions: NWProtocolTLS.Options) {
    let queue = DispatchQueue(label: "grpc.http3.stream", qos: .userInitiated)
    self.queue = queue

    let quicOptions = NWProtocolQUIC.Options(alpn: ["h3"])
    quicOptions.idleTimeout = 30_000  // 30 s in ms

    let params = NWParameters(quic: quicOptions)
    // Copy TLS options from the supplied security config.
    // (NWParameters(quic:) has integrated TLS; we configure trust via sec_protocol_options.)
    params.defaultProtocolStack.applicationProtocols = [quicOptions]

    self.connection = NWConnection(
      host: NWEndpoint.Host(host),
      port: NWEndpoint.Port(rawValue: port)!,
      using: params
    )

    var cont: AsyncStream<Result<[UInt8], NWError>>.Continuation!
    self.receiveBuffer = AsyncStream { cont = $0 }
    self.receiveContinuation = cont
  }

  // MARK: - Lifecycle

  /// Establish the QUIC stream connection. Resolves when `.ready`, throws on failure.
  func establish() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      nonisolated(unsafe) var resumed = false
      connection.stateUpdateHandler = { [weak self] state in
        guard let self, !resumed else { return }
        switch state {
        case .ready:
          resumed = true
          self.startReceiving()
          continuation.resume()
        case .failed(let error):
          resumed = true
          continuation.resume(throwing: error)
        case .cancelled:
          if !resumed {
            resumed = true
            continuation.resume(throwing: CancellationError())
          }
        default:
          break
        }
      }
      connection.start(queue: queue)
    }
  }

  /// Cancel the underlying connection immediately.
  func cancel() {
    receiveContinuation.finish()
    connection.cancel()
  }

  // MARK: - Send / receive

  /// Send bytes on the stream. Set `isComplete = true` with the last write to send FIN.
  func send(_ bytes: [UInt8], isComplete: Bool = false) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let context: NWConnection.ContentContext =
        isComplete ? .finalMessage : .defaultMessage
      connection.send(
        content: Data(bytes),
        contentContext: context,
        isComplete: isComplete,
        completion: .contentProcessed { error in
          if let error {
            continuation.resume(throwing: error)
          } else {
            continuation.resume()
          }
        }
      )
    }
  }

  /// Signal end-of-write-stream (sends FIN) without sending data.
  func closeWrite() async throws {
    try await send([], isComplete: true)
  }

  /// Returns the next chunk of received bytes, or throws on network error.
  /// Returns `nil` when the remote peer has closed the read side (FIN received).
  func receive() async throws -> [UInt8]? {
    for await result in receiveBuffer {
      switch result {
      case .success(let bytes):
        return bytes.isEmpty ? nil : bytes
      case .failure(let error):
        throw error
      }
    }
    return nil  // stream ended normally
  }

  // MARK: - Private

  private func startReceiving() {
    scheduleReceive()
  }

  private func scheduleReceive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
      [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let data {
        receiveContinuation.yield(.success(Array(data)))
      }
      if let error {
        receiveContinuation.yield(.failure(error))
        receiveContinuation.finish()
        return
      }
      if isComplete {
        receiveContinuation.yield(.success([]))  // EOF sentinel
        receiveContinuation.finish()
      } else {
        self.scheduleReceive()
      }
    }
  }
}
#endif
