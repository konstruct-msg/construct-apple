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

/// Variable-length integer encoding per RFC 9000 § 16.
///
/// Used in HTTP/3 frame type and payload-length fields. The 2-bit prefix
/// encodes the byte width: 00 = 1 byte, 01 = 2 bytes, 10 = 4 bytes, 11 = 8 bytes.
enum VarInt {
  static func encode(_ value: UInt64) -> [UInt8] {
    switch value {
    case 0..<0x40:
      return [UInt8(value)]
    case 0x40..<0x4000:
      let v = UInt16(value) | 0x4000
      return [UInt8(v >> 8), UInt8(v & 0xFF)]
    case 0x4000..<0x4000_0000:
      let v = UInt32(value) | 0x8000_0000
      return [
        UInt8(v >> 24), UInt8((v >> 16) & 0xFF),
        UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF),
      ]
    default:
      let v = value | 0xC000_0000_0000_0000
      return [
        UInt8(v >> 56), UInt8((v >> 48) & 0xFF), UInt8((v >> 40) & 0xFF),
        UInt8((v >> 32) & 0xFF), UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
        UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF),
      ]
    }
  }

  /// Returns `(value, bytesConsumed)` or `nil` if the buffer is too short.
  static func decode(_ bytes: [UInt8], at offset: Int = 0) -> (UInt64, Int)? {
    guard offset < bytes.count else { return nil }
    let b = bytes[offset]
    let width = 1 << Int((b >> 6) & 0x03)  // 1, 2, 4, or 8
    guard offset + width <= bytes.count else { return nil }
    var value = UInt64(b & 0x3F)
    for i in 1..<width {
      value = (value << 8) | UInt64(bytes[offset + i])
    }
    return (value, width)
  }
}
