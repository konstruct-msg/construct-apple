//
//  VeilTicketProvisioning.swift
//  Construct Messenger
//
//  Out-of-band veil-front access provisioning. The per-user veil-front ticket is auth
//  material — a probing-resistance secret — so it is NEVER shipped in the binary or
//  published in a public manifest. It arrives as an Ed25519-signed config blob (server
//  email → QR code / `konstruct://veil-config` deep link), is verified against the
//  relay-config signing key, and stored per-relay in the Keychain.
//

import Foundation
import CryptoKit

// MARK: - Ticket store (Keychain)

enum VeilTicketStore {
    private static func key(for address: String) -> String { "veil_front_ticket.\(address)" }

    /// The imported veil-front ticket for `address` (host:port), or nil if none stored.
    static func ticket(for address: String) -> String? {
        guard let data = KeychainManager.shared.loadData(forKey: key(for: address)),
              let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    @discardableResult
    static func store(ticket: String, for address: String) -> Bool {
        guard let data = ticket.data(using: .utf8) else { return false }
        // AfterFirstUnlockThisDeviceOnly — the veil proxy may start on a push-driven
        // background wake before the user unlocks the device.
        return KeychainManager.shared.saveData(
            data, forKey: key(for: address),
            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
    }

    static func clear(for address: String) {
        KeychainManager.shared.deleteData(forKey: key(for: address))
    }
}

// MARK: - Signed config blob

struct VeilConfigBlob {
    let relay: String   // host:port
    let sni: String
    let spki: String    // hex SHA-256 SPKI pin
    let ticket: String  // base64 veil-front ticket
    let exp: Int64?     // unix expiry (nil = no expiry encoded)
}

enum VeilConfigImporter {
    enum ImportError: LocalizedError {
        case malformed, badSignature, expired, unknownRelay, spkiMismatch
        var errorDescription: String? {
            switch self {
            case .malformed:    return NSLocalizedString("veil_import_err_malformed", comment: "")
            case .badSignature, .spkiMismatch:
                return NSLocalizedString("veil_import_err_signature", comment: "")
            case .expired:      return NSLocalizedString("veil_import_err_expired", comment: "")
            case .unknownRelay: return NSLocalizedString("veil_import_err_unknown_relay", comment: "")
            }
        }
    }

    /// Import a base64url-encoded signed config blob (from a scanned QR or a
    /// `konstruct://veil-config?d=<blob>` deep link). Verifies the Ed25519 signature
    /// and that the blob targets a relay we pin, then stores the ticket. Returns the
    /// relay address on success.
    @discardableResult
    static func importBlob(_ blobBase64URL: String) -> Result<String, Error> {
        do {
            let cfg = try parseAndVerify(blobBase64URL: blobBase64URL)
            // The signature proves authenticity; this proves the blob targets the relay
            // we expect (defends against redirection to a rogue relay even with a valid
            // signature). Only relays we ship a pin for are accepted.
            guard let knownSPKI = VEILConfig.hardcodedRelaySPKIs[cfg.relay] else {
                return .failure(ImportError.unknownRelay)
            }
            guard knownSPKI.lowercased() == cfg.spki.lowercased() else {
                return .failure(ImportError.spkiMismatch)
            }
            guard VeilTicketStore.store(ticket: cfg.ticket, for: cfg.relay) else {
                return .failure(ImportError.malformed)
            }
            Log.info("Imported veil-front ticket for \(cfg.relay) (len=\(cfg.ticket.count))", category: "VEIL")
            return .success(cfg.relay)
        } catch {
            Log.error("veil-config import failed: \(error)", category: "VEIL")
            return .failure(error)
        }
    }

    /// Import from a scanned QR or pasted string. Accepts, in order:
    ///   1. a `konstruct://veil-config?d=<blob>` deep-link URL,
    ///   2. a full signed config blob (base64url JSON with relay/spki/signature),
    ///   3. a **bare capability** (base64-std from `make-config-link`) — the most
    ///      ergonomic thing to hand a tester. The relay coords + SPKI come from the
    ///      app's pinned default RU relay (so there's no redirection risk), and the
    ///      capability's own Ed25519 signature is verified client-side before storing.
    @discardableResult
    static func importScannedOrPasted(_ text: String) -> Result<String, Error> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme?.lowercased() == "konstruct" {
            guard let blob = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "d" })?.value else {
                return .failure(ImportError.malformed)
            }
            return importBlob(blob)
        }
        // A signed config blob is base64url-encoded JSON ({...}); a bare capability is
        // base64-std binary. Decode-probe for the JSON shape to route correctly.
        if looksLikeConfigBlob(trimmed) {
            return importBlob(trimmed)
        }
        return importRawCapability(trimmed)
    }

    /// True if `text` base64url-decodes to a JSON object (a signed config blob),
    /// as opposed to a bare capability blob (raw binary).
    private static func looksLikeConfigBlob(_ text: String) -> Bool {
        guard let data = Data(veilBase64URLEncoded: text),
              let obj = try? JSONSerialization.jsonObject(with: data),
              obj is [String: Any] else { return false }
        return true
    }

    /// Import a bare capability (base64-std) for the app's pinned default RU relay.
    /// Verifies the issuer Ed25519 signature and validity window client-side, then
    /// stores the verbatim base64 string (fed as-is to `veil_start`).
    @discardableResult
    static func importRawCapability(_ capabilityBase64: String) -> Result<String, Error> {
        let trimmed = capabilityBase64.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let cap = try parseCapability(trimmed)
            let relay = VEILConfig.ruRelayAddress
            guard VeilTicketStore.store(ticket: trimmed, for: relay) else {
                return .failure(ImportError.malformed)
            }
            Log.info("Imported veil-front capability for \(relay) (scope=\"\(cap.scope)\", exp=\(cap.notAfter), len=\(trimmed.count))", category: "VEIL")
            return .success(relay)
        } catch {
            Log.error("veil capability import failed: \(error)", category: "VEIL")
            return .failure(error)
        }
    }

    static func parseAndVerify(blobBase64URL: String) throws -> VeilConfigBlob {
        guard let jsonData = Data(veilBase64URLEncoded: blobBase64URL),
              let obj = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any] else {
            throw ImportError.malformed
        }
        guard try verifySignature(jsonObject: obj) else { throw ImportError.badSignature }
        guard let relay = obj["relay"] as? String, !relay.isEmpty,
              let spki = obj["spki"] as? String, !spki.isEmpty else {
            throw ImportError.malformed
        }
        // New blobs carry a `capability` (backend-signed); tolerate the legacy `ticket`
        // key during the cutover. The stored string is fed verbatim to veil_start.
        guard let capability = (obj["capability"] as? String) ?? (obj["ticket"] as? String),
              !capability.isEmpty else {
            throw ImportError.malformed
        }
        let sni = (obj["sni"] as? String) ?? relay.components(separatedBy: ":").first ?? relay
        let exp = (obj["exp"] as? NSNumber)?.int64Value
        if let exp, exp < Int64(Date().timeIntervalSince1970) { throw ImportError.expired }
        return VeilConfigBlob(relay: relay, sni: sni, spki: spki, ticket: capability, exp: exp)
    }

    /// Ed25519 over canonical JSON (sorted keys, no `signature` field) — the same
    /// signing scheme as the relay manifest (`VeilCertFetcher.verifySignature`), so the
    /// server can sign config blobs with the existing `relayConfigSigningKey`.
    private static func verifySignature(jsonObject: [String: Any]) throws -> Bool {
        var obj = jsonObject
        guard let sigField = obj["signature"] as? String, sigField.hasPrefix("ed25519:"),
              let sigData = Data(veilBase64URLEncoded: String(sigField.dropFirst("ed25519:".count)))
        else { return false }
        obj.removeValue(forKey: "signature")
        let canonical = try JSONSerialization.data(
            withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard let pubKeyData = Data(veilHexString: VEILConfig.relayConfigSigningKey) else { return false }
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: pubKeyData)
        return publicKey.isValidSignature(sigData, for: canonical)
    }

    // MARK: - Bare capability parsing

    /// The fields we surface from a parsed capability (for logging / future renewal).
    struct ParsedCapability {
        let scope: String
        let notBefore: UInt64
        let notAfter: UInt64
    }

    /// Capability blob layout (must match construct-veil-protocol `Capability::encode`):
    ///   ticket_id[16] ‖ auth_key[32] ‖ not_before[8 LE] ‖ not_after[8 LE]
    ///   ‖ suite_id[1] ‖ scope_len[u8] ‖ scope[scope_len] ‖ sig[64]
    /// The issuer-signed message is `"veil-cap-v1" ‖ blob[0..<65] ‖ scope` (the fixed
    /// fields without scope_len, plus the scope bytes). We verify that Ed25519
    /// signature against `relayConfigSigningKey` — the same offline check the relay does.
    static func parseCapability(_ capabilityBase64: String) throws -> ParsedCapability {
        guard let blob = Data(base64Encoded: capabilityBase64) else { throw ImportError.malformed }
        let bytes = [UInt8](blob)
        let fixed = 16 + 32 + 8 + 8 + 1 + 1   // 66 — through scope_len
        let sigLen = 64
        guard bytes.count >= fixed else { throw ImportError.malformed }
        let scopeLen = Int(bytes[65])
        guard bytes.count == fixed + scopeLen + sigLen else { throw ImportError.malformed }

        let notBefore = readU64LE(bytes[48..<56])
        let notAfter = readU64LE(bytes[56..<64])
        let scopeBytes = bytes[66..<(66 + scopeLen)]
        let scope = String(bytes: scopeBytes, encoding: .utf8) ?? ""
        let sig = Data(bytes[(66 + scopeLen)...])

        // Reconstruct the issuer-signed message and verify the Ed25519 signature.
        var msg = Data("veil-cap-v1".utf8)
        msg.append(Data(bytes[0..<65]))
        msg.append(Data(scopeBytes))
        guard let pubKeyData = Data(veilHexString: VEILConfig.relayConfigSigningKey),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pubKeyData),
              publicKey.isValidSignature(sig, for: msg) else {
            throw ImportError.badSignature
        }

        // Validity window (not_after == 0 means "no expiry encoded").
        let now = UInt64(max(0, Date().timeIntervalSince1970))
        if notAfter != 0 && now > notAfter { throw ImportError.expired }

        return ParsedCapability(scope: scope, notBefore: notBefore, notAfter: notAfter)
    }

    private static func readU64LE(_ slice: ArraySlice<UInt8>) -> UInt64 {
        var v: UInt64 = 0
        for (i, b) in slice.enumerated() { v |= UInt64(b) << (8 * i) }
        return v
    }
}

private extension Data {
    /// Decode a base64url (no-padding) string.
    init?(veilBase64URLEncoded string: String) {
        var b64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = b64.count % 4
        if rem > 0 { b64 += String(repeating: "=", count: 4 - rem) }
        self.init(base64Encoded: b64)
    }

    /// Decode a lowercase/uppercase hex string into bytes.
    init?(veilHexString hex: String) {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            bytes.append(b)
            i += 2
        }
        self = Data(bytes)
    }
}
