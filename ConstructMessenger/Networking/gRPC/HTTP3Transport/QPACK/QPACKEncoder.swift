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

/// Static-table-only QPACK encoder (RFC 9204).
///
/// Encodes headers as:
/// - **Indexed field lines** (§ 4.5.2) when both name+value match a static entry.
/// - **Literal field lines with static name reference** (§ 4.5.4) when only the name matches.
/// - **Literal field lines with literal name** (§ 4.5.6) for everything else.
///
/// No dynamic table, no Huffman encoding. The Required Insert Count is always 0,
/// which means the encoded field section can be decoded without dynamic table state.
enum QPACKEncoder {
  // MARK: - Public API

  /// Encode `headers` into a QPACK-encoded field section ready to place in an HTTP/3 HEADERS frame.
  static func encode(_ headers: [(name: String, value: String)]) -> [UInt8] {
    // Encoded Field Section Prefix (RFC 9204 § 4.5.1):
    //   Required Insert Count = 0  → one byte: 0x00
    //   Sign-bit = 0, Delta Base = 0 → one byte: 0x00
    var out: [UInt8] = [0x00, 0x00]

    for (name, value) in headers {
      if let (index, exact) = QPACKStaticTable.find(name: name, value: value) {
        if exact {
          // Indexed field line — static (§ 4.5.2):  1 T=1 index(6-bit)
          out += QPACKInt.encode(UInt64(index), prefixBits: 6).enumerated().map { i, b in
            i == 0 ? b | 0b1100_0000 : b
          }
        } else {
          // Literal with static name reference (§ 4.5.4):  0 1 0 N=0 T=1 index(4-bit)
          let indexBytes = QPACKInt.encode(UInt64(index), prefixBits: 4)
          out += indexBytes.enumerated().map { i, b in
            i == 0 ? b | 0b0101_0000 : b
          }
          out += literalString(value)
        }
      } else {
        // Literal field line with literal name (§ 4.5.6):  0 0 1 N=0 H=0 (3-bit reserved = 000)
        out.append(0b0010_0000)
        out += literalString(name)
        out += literalString(value)
      }
    }
    return out
  }

  // MARK: - Private helpers

  /// Encode a string as `H=0 (no Huffman) | length(7-bit) | utf8-bytes`.
  private static func literalString(_ s: String) -> [UInt8] {
    let utf8 = Array(s.utf8)
    var out = QPACKInt.encode(UInt64(utf8.count), prefixBits: 7)
    // H=0 means first byte has MSB = 0, which QPACKInt already produces.
    out += utf8
    return out
  }
}
