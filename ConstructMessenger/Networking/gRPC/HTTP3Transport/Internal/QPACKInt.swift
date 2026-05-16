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

/// HPACK/QPACK-style integer encoding (RFC 7541 § 5.1, RFC 9204).
///
/// Unlike the QUIC `VarInt` (which uses a fixed 2-bit prefix), this uses a
/// caller-specified prefix width (1–8 bits), with multi-byte continuation
/// using MSB = 1 as the "more bytes" flag.
enum QPACKInt {
  /// Encode `value` using a `prefixBits`-bit prefix.
  /// The caller is responsible for OR-ing the returned first byte with
  /// any flag bits that occupy the high bits of that first byte.
  static func encode(_ value: UInt64, prefixBits: Int) -> [UInt8] {
    precondition((1...8).contains(prefixBits))
    let maxPrefix = UInt64((1 << prefixBits) - 1)
    if value < maxPrefix {
      return [UInt8(value)]
    }
    var bytes: [UInt8] = [UInt8(maxPrefix)]
    var remainder = value - maxPrefix
    while remainder >= 128 {
      bytes.append(UInt8((remainder & 0x7F) | 0x80))
      remainder >>= 7
    }
    bytes.append(UInt8(remainder))
    return bytes
  }

  /// Decode a QPACK integer with `prefixBits`-bit prefix starting at `offset`.
  ///
  /// The high bits of `bytes[offset]` above the prefix must already be masked
  /// by the caller. Returns `(value, bytesConsumed)` or `nil` on truncation.
  static func decode(_ bytes: [UInt8], at offset: Int = 0, prefixBits: Int) -> (UInt64, Int)? {
    guard offset < bytes.count else { return nil }
    let maxPrefix = UInt64((1 << prefixBits) - 1)
    let firstValue = UInt64(bytes[offset]) & maxPrefix
    if firstValue < maxPrefix {
      return (firstValue, 1)
    }
    var value = firstValue
    var i = 1
    var shift: UInt64 = 0
    while offset + i < bytes.count {
      let byte = bytes[offset + i]
      i += 1
      value += UInt64(byte & 0x7F) << shift
      shift += 7
      if (byte & 0x80) == 0 {
        return (value, i)
      }
    }
    return nil  // truncated
  }
}
