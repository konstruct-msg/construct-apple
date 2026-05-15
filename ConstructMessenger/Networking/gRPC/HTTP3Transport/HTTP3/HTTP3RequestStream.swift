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

/// Manages one gRPC call over a single HTTP/3 (QUIC) bidirectional stream.
///
/// ## Wire layout per RFC 9114 + gRPC-over-HTTP/2 framing spec
///
/// **Request (client→server):**
/// ```
/// HEADERS frame: QPACK-encoded :method POST, :path, :authority, content-type, te
/// DATA frame(s): 5-byte gRPC length-prefix header + serialised proto message
/// FIN (end of write stream)
/// ```
///
/// **Response (server→client):**
/// ```
/// HEADERS frame: :status 200, content-type application/grpc
/// DATA frame(s): 5-byte gRPC prefix + proto message
/// HEADERS frame (trailers): grpc-status, [grpc-message]
/// FIN
/// ```
struct HTTP3RequestStream {
  private let stream: QUICStreamConnection
  private let authority: String
  private let methodPath: String  // e.g. "/helloworld.Greeter/SayHello"

  init(stream: QUICStreamConnection, authority: String, methodPath: String) {
    self.stream = stream
    self.authority = authority
    self.methodPath = methodPath
  }

  /// Cancel the underlying QUIC stream immediately.
  func cancel() {
    stream.cancel()
  }

  // MARK: - Send

  /// Send the gRPC request headers and body, then close the write side.
  func sendRequest(message: [UInt8], compression: String = "identity") async throws {
    let headers: [(name: String, value: String)] = [
      (":method", "POST"),
      (":scheme", "https"),
      (":path", methodPath),
      (":authority", authority),
      ("content-type", "application/grpc"),
      ("te", "trailers"),
      ("grpc-encoding", compression),
    ]
    let encodedHeaders = QPACKEncoder.encode(headers)
    let headersFrame = HTTP3Frame.headers(encodedHeaders).encoded

    let grpcFrame = grpcLengthPrefix(message, compressed: false)
    let dataFrame = HTTP3Frame.data(grpcFrame).encoded

    try await stream.send(headersFrame + dataFrame, isComplete: true)
  }

  /// Send request headers for a streaming call (does not close write side).
  func sendStreamingHeaders(compression: String = "identity") async throws {
    let headers: [(name: String, value: String)] = [
      (":method", "POST"),
      (":scheme", "https"),
      (":path", methodPath),
      (":authority", authority),
      ("content-type", "application/grpc"),
      ("te", "trailers"),
      ("grpc-encoding", compression),
    ]
    let encodedHeaders = QPACKEncoder.encode(headers)
    try await stream.send(HTTP3Frame.headers(encodedHeaders).encoded)
  }

  /// Send one gRPC message on a streaming call.
  func sendMessage(_ message: [UInt8], compressed: Bool = false) async throws {
    let grpcFrame = grpcLengthPrefix(message, compressed: compressed)
    try await stream.send(HTTP3Frame.data(grpcFrame).encoded)
  }

  /// Close the write side after all messages have been sent.
  func finishSending() async throws {
    try await stream.closeWrite()
  }

  // MARK: - Receive

  /// Drain all response frames and call `onMessage` for each gRPC message.
  ///
  /// Returns the trailing metadata (grpc-status, grpc-message, etc.) on success,
  /// or throws an `RPCError` if the server signals a gRPC error status.
  func receiveResponse(
    onMessage: ([UInt8]) throws -> Void
  ) async throws -> [(name: String, value: String)] {
    let parser = HTTP3FrameParser()
    var responseHeadersReceived = false
    var trailers: [(name: String, value: String)] = []

    while let chunk = try await stream.receive() {
      parser.append(chunk)
      while let frame = parser.next() {
        switch frame.type {
        case HTTP3FrameType.headers.rawValue:
          let hdrs = try QPACKDecoder.decode(frame.payload)
          if !responseHeadersReceived {
            responseHeadersReceived = true
            // Validate :status = 200
            let status = hdrs.first(where: { $0.name == ":status" })?.value
            guard status == "200" else {
              throw RPCError(
                code: .unavailable,
                message: "HTTP/3 status \(status ?? "unknown") (expected 200)"
              )
            }
          } else {
            // Trailers: contains grpc-status
            trailers = hdrs
          }

        case HTTP3FrameType.data.rawValue:
          // One HTTP/3 DATA frame may contain multiple gRPC messages.
          var grpcBytes = frame.payload
          while !grpcBytes.isEmpty {
            guard let (message, consumed) = parseGRPCMessage(grpcBytes) else { break }
            try onMessage(message)
            grpcBytes = Array(grpcBytes.dropFirst(consumed))
          }

        default:
          // Ignore unknown frame types (RFC 9114 § 9).
          break
        }
      }
    }

    // Validate gRPC status from trailers.
    if let statusStr = trailers.first(where: { $0.name == "grpc-status" })?.value,
      let statusCode = Int(statusStr),
      statusCode != 0
    {
      let message =
        trailers.first(where: { $0.name == "grpc-message" })?.value
        ?? "gRPC status \(statusCode)"
      let rpcCode = Status.Code(rawValue: statusCode).flatMap { RPCError.Code($0) } ?? .unknown
      throw RPCError(code: rpcCode, message: message)
    }

    return trailers
  }

  // MARK: - Private helpers

  private func grpcLengthPrefix(_ message: [UInt8], compressed: Bool) -> [UInt8] {
    let flag: UInt8 = compressed ? 1 : 0
    let length = UInt32(message.count)
    return [
      flag,
      UInt8((length >> 24) & 0xFF),
      UInt8((length >> 16) & 0xFF),
      UInt8((length >> 8) & 0xFF),
      UInt8(length & 0xFF),
    ] + message
  }

  /// Parse one gRPC length-prefixed message from the front of `bytes`.
  /// Returns `(message, totalBytesConsumed)` or `nil` if insufficient data.
  private func parseGRPCMessage(_ bytes: [UInt8]) -> ([UInt8], Int)? {
    guard bytes.count >= 5 else { return nil }
    let length = Int(bytes[1]) << 24 | Int(bytes[2]) << 16 | Int(bytes[3]) << 8 | Int(bytes[4])
    guard bytes.count >= 5 + length else { return nil }
    return (Array(bytes[5..<5 + length]), 5 + length)
  }
}
#endif
