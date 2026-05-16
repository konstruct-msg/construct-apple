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

/// The 99-entry QPACK static table (RFC 9204, Appendix A).
///
/// Indices are 0-based as per the spec (unlike HPACK's 1-based table).
struct QPACKStaticTable {
  struct Entry: Sendable {
    let name: String
    let value: String
  }

  /// All 99 static table entries. Index 0 = first entry.
  static let entries: [Entry] = [
    /* 0 */ Entry(name: ":authority", value: ""),
    /* 1 */ Entry(name: ":path", value: "/"),
    /* 2 */ Entry(name: "age", value: "0"),
    /* 3 */ Entry(name: "content-disposition", value: ""),
    /* 4 */ Entry(name: "content-length", value: "0"),
    /* 5 */ Entry(name: "cookie", value: ""),
    /* 6 */ Entry(name: "date", value: ""),
    /* 7 */ Entry(name: "etag", value: ""),
    /* 8 */ Entry(name: "if-modified-since", value: ""),
    /* 9 */ Entry(name: "if-none-match", value: ""),
    /* 10 */ Entry(name: "last-modified", value: ""),
    /* 11 */ Entry(name: "link", value: ""),
    /* 12 */ Entry(name: "location", value: ""),
    /* 13 */ Entry(name: "referer", value: ""),
    /* 14 */ Entry(name: "set-cookie", value: ""),
    /* 15 */ Entry(name: ":method", value: "CONNECT"),
    /* 16 */ Entry(name: ":method", value: "DELETE"),
    /* 17 */ Entry(name: ":method", value: "GET"),
    /* 18 */ Entry(name: ":method", value: "HEAD"),
    /* 19 */ Entry(name: ":method", value: "OPTIONS"),
    /* 20 */ Entry(name: ":method", value: "POST"),
    /* 21 */ Entry(name: ":method", value: "PUT"),
    /* 22 */ Entry(name: ":scheme", value: "http"),
    /* 23 */ Entry(name: ":scheme", value: "https"),
    /* 24 */ Entry(name: ":status", value: "103"),
    /* 25 */ Entry(name: ":status", value: "200"),
    /* 26 */ Entry(name: ":status", value: "304"),
    /* 27 */ Entry(name: ":status", value: "404"),
    /* 28 */ Entry(name: ":status", value: "503"),
    /* 29 */ Entry(name: "accept", value: "*/*"),
    /* 30 */ Entry(name: "accept", value: "application/dns-message"),
    /* 31 */ Entry(name: "accept-encoding", value: "gzip, deflate, br"),
    /* 32 */ Entry(name: "accept-ranges", value: "bytes"),
    /* 33 */ Entry(name: "access-control-allow-headers", value: "cache-control"),
    /* 34 */ Entry(name: "access-control-allow-headers", value: "content-type"),
    /* 35 */ Entry(name: "access-control-allow-origin", value: "*"),
    /* 36 */ Entry(name: "cache-control", value: "max-age=0"),
    /* 37 */ Entry(name: "cache-control", value: "max-age=2592000"),
    /* 38 */ Entry(name: "cache-control", value: "max-age=31536000"),
    /* 39 */ Entry(name: "cache-control", value: "no-cache"),
    /* 40 */ Entry(name: "cache-control", value: "no-store"),
    /* 41 */ Entry(name: "cache-control", value: "public, max-age=31536000"),
    /* 42 */ Entry(name: "content-encoding", value: "br"),
    /* 43 */ Entry(name: "content-encoding", value: "gzip"),
    /* 44 */ Entry(name: "content-type", value: "application/dns-message"),
    /* 45 */ Entry(name: "content-type", value: "application/javascript"),
    /* 46 */ Entry(name: "content-type", value: "application/json"),
    /* 47 */ Entry(name: "content-type", value: "application/x-www-form-urlencoded"),
    /* 48 */ Entry(name: "content-type", value: "image/gif"),
    /* 49 */ Entry(name: "content-type", value: "image/jpeg"),
    /* 50 */ Entry(name: "content-type", value: "image/png"),
    /* 51 */ Entry(name: "content-type", value: "text/css"),
    /* 52 */ Entry(name: "content-type", value: "text/html; charset=utf-8"),
    /* 53 */ Entry(name: "content-type", value: "text/plain"),
    /* 54 */ Entry(name: "content-type", value: "text/plain;charset=utf-8"),
    /* 55 */ Entry(name: "range", value: "bytes=0-"),
    /* 56 */ Entry(name: "strict-transport-security", value: "max-age=31536000"),
    /* 57 */ Entry(name: "strict-transport-security", value: "max-age=31536000; includesubdomains"),
    /* 58 */ Entry(name: "strict-transport-security", value: "max-age=31536000; includesubdomains; preload"),
    /* 59 */ Entry(name: "vary", value: "accept-encoding"),
    /* 60 */ Entry(name: "vary", value: "origin"),
    /* 61 */ Entry(name: "x-content-type-options", value: "nosniff"),
    /* 62 */ Entry(name: "x-xss-protection", value: "1; mode=block"),
    /* 63 */ Entry(name: ":status", value: "100"),
    /* 64 */ Entry(name: ":status", value: "204"),
    /* 65 */ Entry(name: ":status", value: "206"),
    /* 66 */ Entry(name: ":status", value: "302"),
    /* 67 */ Entry(name: ":status", value: "400"),
    /* 68 */ Entry(name: ":status", value: "403"),
    /* 69 */ Entry(name: ":status", value: "421"),
    /* 70 */ Entry(name: ":status", value: "425"),
    /* 71 */ Entry(name: ":status", value: "500"),
    /* 72 */ Entry(name: "accept-language", value: ""),
    /* 73 */ Entry(name: "access-control-allow-credentials", value: "FALSE"),
    /* 74 */ Entry(name: "access-control-allow-credentials", value: "TRUE"),
    /* 75 */ Entry(name: "access-control-allow-headers", value: "*"),
    /* 76 */ Entry(name: "access-control-allow-methods", value: "get"),
    /* 77 */ Entry(name: "access-control-allow-methods", value: "get, post, options"),
    /* 78 */ Entry(name: "access-control-allow-methods", value: "options"),
    /* 79 */ Entry(name: "access-control-allow-origin", value: ""),
    /* 80 */ Entry(name: "access-control-expose-headers", value: "content-length"),
    /* 81 */ Entry(name: "access-control-request-headers", value: "content-type"),
    /* 82 */ Entry(name: "access-control-request-method", value: "get"),
    /* 83 */ Entry(name: "access-control-request-method", value: "post"),
    /* 84 */ Entry(name: "alt-svc", value: "clear"),
    /* 85 */ Entry(name: "authorization", value: ""),
    /* 86 */ Entry(name: "content-security-policy", value: "script-src 'none'; object-src 'none'; base-uri 'none'"),
    /* 87 */ Entry(name: "early-data", value: "1"),
    /* 88 */ Entry(name: "expect-ct", value: ""),
    /* 89 */ Entry(name: "forwarded", value: ""),
    /* 90 */ Entry(name: "if-range", value: ""),
    /* 91 */ Entry(name: "origin", value: ""),
    /* 92 */ Entry(name: "purpose", value: "prefetch"),
    /* 93 */ Entry(name: "server", value: ""),
    /* 94 */ Entry(name: "timing-allow-origin", value: "*"),
    /* 95 */ Entry(name: "upgrade-insecure-requests", value: "1"),
    /* 96 */ Entry(name: "user-agent", value: ""),
    /* 97 */ Entry(name: "x-forwarded-for", value: ""),
    /* 98 */ Entry(name: "x-frame-options", value: "deny"),
    /* 99 */ Entry(name: "x-frame-options", value: "sameorigin"),
  ]

  // MARK: - Lookup helpers

  /// Returns `(index, exactValueMatch)` for the best static-table match on `name`+`value`.
  ///
  /// - Returns `(index, true)` when both name and value match.
  /// - Returns `(index, false)` when only the name matches.
  /// - Returns `nil` when the name is not in the table at all.
  static func find(name: String, value: String) -> (Int, Bool)? {
    var nameOnly: Int? = nil
    for (idx, entry) in entries.enumerated() {
      guard entry.name == name else { continue }
      if entry.value == value { return (idx, true) }
      if nameOnly == nil { nameOnly = idx }
    }
    return nameOnly.map { ($0, false) }
  }

  /// Returns the entry at `index`, or `nil` for out-of-range indices.
  static func entry(at index: Int) -> Entry? {
    guard index >= 0 && index < entries.count else { return nil }
    return entries[index]
  }
}
