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

/// HTTP/3 frame types per RFC 9114 § 7.2.
enum HTTP3FrameType: UInt64 {
  case data = 0x00
  case headers = 0x01
  case cancelPush = 0x03
  case settings = 0x04
  case pushPromise = 0x05
  case goAway = 0x07
  case maxPushID = 0x0D
}

/// A single HTTP/3 frame: type (varint) + payload length (varint) + payload.
struct HTTP3Frame {
  let type: UInt64
  let payload: [UInt8]

  /// Serialise to wire bytes.
  var encoded: [UInt8] {
    var out = VarInt.encode(type)
    out += VarInt.encode(UInt64(payload.count))
    out += payload
    return out
  }

  // MARK: - Convenience constructors

  static func settings(_ pairs: [(UInt64, UInt64)]) -> HTTP3Frame {
    var payload: [UInt8] = []
    for (id, value) in pairs {
      payload += VarInt.encode(id)
      payload += VarInt.encode(value)
    }
    return HTTP3Frame(type: HTTP3FrameType.settings.rawValue, payload: payload)
  }

  static func headers(_ encodedFieldSection: [UInt8]) -> HTTP3Frame {
    HTTP3Frame(type: HTTP3FrameType.headers.rawValue, payload: encodedFieldSection)
  }

  static func data(_ grpcMessage: [UInt8]) -> HTTP3Frame {
    HTTP3Frame(type: HTTP3FrameType.data.rawValue, payload: grpcMessage)
  }
}

/// Incremental HTTP/3 frame parser.
///
/// Feed incoming bytes via `append(_:)`, then drain parsed frames via `next()`.
final class HTTP3FrameParser: @unchecked Sendable {
  private var buffer: [UInt8] = []

  func append(_ bytes: [UInt8]) {
    buffer += bytes
  }

  /// Returns the next fully-buffered frame, or `nil` if more bytes are needed.
  func next() -> HTTP3Frame? {
    var offset = 0

    guard let (type, typeLen) = VarInt.decode(buffer, at: offset) else { return nil }
    offset += typeLen

    guard let (payloadLen, lenLen) = VarInt.decode(buffer, at: offset) else { return nil }
    offset += lenLen

    let end = offset + Int(payloadLen)
    guard end <= buffer.count else { return nil }

    let frame = HTTP3Frame(type: type, payload: Array(buffer[offset..<end]))
    buffer.removeFirst(end)
    return frame
  }
}
