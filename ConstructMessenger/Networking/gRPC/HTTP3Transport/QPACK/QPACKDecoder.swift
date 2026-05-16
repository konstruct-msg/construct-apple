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

/// QPACK decoder for static-table-only encoded field sections (RFC 9204).
///
/// Handles the field-line representations that a well-behaved HTTP/3 server
/// will send for gRPC responses:
import Foundation
/// - Indexed field lines from the static table (§ 4.5.2)
/// - Literal field lines with static name reference (§ 4.5.4)
/// - Literal field lines with post-base name reference (§ 4.5.5 — decoded as literal)
/// - Literal field lines with literal name (§ 4.5.6)
///
/// Dynamic table entries are NOT supported. A server that requires dynamic table
/// entries will trigger a decode error.
enum QPACKDecoder {
  enum DecodeError: Error, Sendable {
    case truncated
    case dynamicTableRequired
    case invalidEncoding(String)
  }

  // MARK: - Public API

  /// Decode a QPACK-encoded field section into `[(name, value)]` pairs.
  ///
  /// - Parameter bytes: The raw payload of an HTTP/3 HEADERS frame.
  static func decode(_ bytes: [UInt8]) throws(DecodeError) -> [(name: String, value: String)] {
    var offset = 0

    // Skip the Encoded Field Section Prefix (Required Insert Count + Base).
    guard let (ric, ricLen) = QPACKInt.decode(bytes, at: offset, prefixBits: 8) else {
      throw DecodeError.truncated
    }
    offset += ricLen
    guard offset < bytes.count else { throw DecodeError.truncated }

    let signAndBase = bytes[offset]
    guard let (_, baseLen) = QPACKInt.decode(bytes, at: offset, prefixBits: 7) else {
      throw DecodeError.truncated
    }
    offset += baseLen

    // If RIC != 0 the server referenced dynamic table entries we don't have.
    if ric != 0 {
      throw DecodeError.dynamicTableRequired
    }
    _ = signAndBase  // base delta = 0; validated via ric == 0

    var headers: [(name: String, value: String)] = []

    while offset < bytes.count {
      let b = bytes[offset]

      if b & 0b1000_0000 != 0 {
        // § 4.5.2 — Indexed field line
        // Bit pattern: 1 T index(6-bit)
        let isStatic = (b & 0b0100_0000) != 0
        guard let (index, len) = QPACKInt.decode(bytes, at: offset, prefixBits: 6) else {
          throw DecodeError.truncated
        }
        offset += len
        if isStatic {
          guard let entry = QPACKStaticTable.entry(at: Int(index)) else {
            throw DecodeError.invalidEncoding("static table index \(index) out of range")
          }
          headers.append((entry.name, entry.value))
        } else {
          // Dynamic table indexed reference — not supported
          throw DecodeError.dynamicTableRequired
        }

      } else if b & 0b1100_0000 == 0b0100_0000 {
        // § 4.5.4 — Literal field line with name reference
        // Bit pattern: 0 1 0 N T index(4-bit)
        let isStatic = (b & 0b0001_0000) != 0
        guard let (index, idxLen) = QPACKInt.decode(bytes, at: offset, prefixBits: 4) else {
          throw DecodeError.truncated
        }
        offset += idxLen

        let (value, valLen) = try decodeLiteralString(bytes, at: offset)
        offset += valLen

        if isStatic {
          guard let entry = QPACKStaticTable.entry(at: Int(index)) else {
            throw DecodeError.invalidEncoding("static table name index \(index) out of range")
          }
          headers.append((entry.name, value))
        } else {
          throw DecodeError.dynamicTableRequired
        }

      } else if b & 0b1111_0000 == 0b0001_0000 {
        // § 4.5.5 — Literal field line with post-base name reference
        // Bit pattern: 0 0 0 1 N index(3-bit)  — always dynamic; reject
        throw DecodeError.dynamicTableRequired

      } else if b & 0b1110_0000 == 0b0010_0000 {
        // § 4.5.6 — Literal field line with literal name
        // Bit pattern: 0 0 1 N H name-length name-bytes value
        offset += 1  // consume this byte (flag byte, name H bit is in next QPACKInt call)
        let (name, nameLen) = try decodeLiteralString(bytes, at: offset)
        offset += nameLen
        let (value, valLen) = try decodeLiteralString(bytes, at: offset)
        offset += valLen
        headers.append((name, value))

      } else if b & 0b1111_0000 == 0b0000_0000 {
        // § 4.5.7 — Literal field line with post-base name reference (alternate)
        // Bit pattern: 0 0 0 0 N H name-length ... — always dynamic; reject
        throw DecodeError.dynamicTableRequired

      } else {
        throw DecodeError.invalidEncoding(
          String(format: "unrecognised field-line prefix byte: 0x%02X", b))
      }
    }

    return headers
  }

  // MARK: - Private helpers

  /// Decode a QPACK literal string: H-bit (Huffman flag) + 7-bit length prefix + bytes.
  /// Returns `(string, bytesConsumed)`. Huffman encoding is not supported.
  private static func decodeLiteralString(
    _ bytes: [UInt8],
    at offset: Int
  ) throws(DecodeError) -> (String, Int) {
    guard offset < bytes.count else { throw DecodeError.truncated }
    let huffman = (bytes[offset] & 0x80) != 0
    guard !huffman else {
      throw DecodeError.invalidEncoding("Huffman-encoded strings not supported")
    }
    guard let (length, lenBytes) = QPACKInt.decode(bytes, at: offset, prefixBits: 7) else {
      throw DecodeError.truncated
    }
    let start = offset + lenBytes
    let end = start + Int(length)
    guard end <= bytes.count else { throw DecodeError.truncated }
    let str = String(bytes: bytes[start..<end], encoding: .utf8) ?? ""
    return (str, lenBytes + Int(length))
  }
}
