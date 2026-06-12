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

    /// Import from a scanned QR or pasted string — accepts either the raw base64url
    /// blob or a full `konstruct://veil-config?d=<blob>` deep-link URL.
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
        return importBlob(trimmed)
    }

    static func parseAndVerify(blobBase64URL: String) throws -> VeilConfigBlob {
        guard let jsonData = Data(veilBase64URLEncoded: blobBase64URL),
              let obj = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any] else {
            throw ImportError.malformed
        }
        guard try verifySignature(jsonObject: obj) else { throw ImportError.badSignature }
        guard let relay = obj["relay"] as? String, !relay.isEmpty,
              let spki = obj["spki"] as? String, !spki.isEmpty,
              let ticket = obj["ticket"] as? String, !ticket.isEmpty else {
            throw ImportError.malformed
        }
        let sni = (obj["sni"] as? String) ?? relay.components(separatedBy: ":").first ?? relay
        let exp = (obj["exp"] as? NSNumber)?.int64Value
        if let exp, exp < Int64(Date().timeIntervalSince1970) { throw ImportError.expired }
        return VeilConfigBlob(relay: relay, sni: sni, spki: spki, ticket: ticket, exp: exp)
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
