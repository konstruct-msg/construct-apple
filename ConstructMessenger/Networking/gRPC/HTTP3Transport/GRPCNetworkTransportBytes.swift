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

import Foundation
import GRPCCore

/// `GRPCContiguousBytes` wrapping `Foundation.Data` for use in the HTTP/3 transport.
///
/// This type avoids a dependency on `NIOCore.ByteBuffer` so that the HTTP/3 transport
/// can be built without any SwiftNIO dependency.
struct GRPCNetworkTransportBytes: GRPCContiguousBytes, Sendable, Hashable {
  @usableFromInline
  var _storage: Data

  init(_ data: Data = Data()) {
    self._storage = data
  }

  init(repeating byte: UInt8, count: Int) {
    self._storage = Data(repeating: byte, count: count)
  }

  public init<Bytes: Sequence>(_ sequence: Bytes) where Bytes.Element == UInt8 {
    self._storage = Data(sequence)
  }

  var count: Int { _storage.count }

  func withUnsafeBytes<R>(
    _ body: (UnsafeRawBufferPointer) throws -> R
  ) rethrows -> R {
    try _storage.withUnsafeBytes(body)
  }

  public mutating func withUnsafeMutableBytes<R>(
    _ body: (UnsafeMutableRawBufferPointer) throws -> R
  ) rethrows -> R {
    try _storage.withUnsafeMutableBytes(body)
  }

  public mutating func append(contentsOf other: GRPCNetworkTransportBytes) {
    _storage.append(other._storage)
  }

  public mutating func append(contentsOf bytes: some Collection<UInt8>) {
    _storage.append(contentsOf: bytes)
  }

  /// Access the underlying `Foundation.Data`.
  var data: Data { _storage }
}

extension GRPCNetworkTransportBytes: ExpressibleByArrayLiteral {
  init(arrayLiteral elements: UInt8...) {
    self._storage = Data(elements)
  }
}
