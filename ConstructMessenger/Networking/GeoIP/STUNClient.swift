import Foundation
import Network

// Minimal STUN binding-request client (RFC 5389).
// Sends one UDP binding request, parses XOR-MAPPED-ADDRESS from the response.
// Used only to determine the device's public IPv4 address for GeoIP lookup.
enum STUNClient {

    private static let servers: [(host: String, port: UInt16)] = [
        ("stun.cloudflare.com", 3478),
        ("stun.l.google.com", 19302),
        ("stun1.l.google.com", 19302),
    ]

    static func publicIP(timeout: TimeInterval = 3.0) async -> String? {
        for server in servers {
            if let ip = await query(host: server.host, port: server.port, timeout: timeout) {
                return ip
            }
        }
        return nil
    }

    // MARK: - STUN binding request / response

    private static func query(host: String, port: UInt16, timeout: TimeInterval) async -> String? {
        let txID = (0..<12).map { _ in UInt8.random(in: 0...255) }
        let request = buildBindingRequest(txID: txID)

        return await withCheckedContinuation { continuation in
            let endpoint = NWEndpoint.hostPort(host: .init(host), port: .init(rawValue: port)!)
            let connection = NWConnection(to: endpoint, using: .udp)
            let done = AtomicFlag()

            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    connection.send(content: request, completion: .contentProcessed { _ in })
                    connection.receive(minimumIncompleteLength: 20, maximumLength: 512) { data, _, _, _ in
                        let ip = data.flatMap { parseResponse($0, txID: txID) }
                        if done.set() { connection.cancel(); continuation.resume(returning: ip) }
                    }
                } else if case .failed = state {
                    if done.set() { continuation.resume(returning: nil) }
                }
            }
            connection.start(queue: .global(qos: .utility))

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if done.set() { connection.cancel(); continuation.resume(returning: nil) }
            }
        }
    }

    // MARK: - Message construction

    // STUN Binding Request (no attributes):
    // 2 bytes type (0x0001) + 2 bytes length (0x0000) + 4 bytes magic (0x2112A442) + 12 bytes txID
    private static func buildBindingRequest(txID: [UInt8]) -> Data {
        var bytes: [UInt8] = [
            0x00, 0x01,  // Binding Request
            0x00, 0x00,  // Message length (no attributes)
            0x21, 0x12, 0xa4, 0x42,  // Magic cookie
        ]
        bytes += txID
        return Data(bytes)
    }

    // MARK: - Response parsing

    private static func parseResponse(_ data: Data, txID: [UInt8]) -> String? {
        guard data.count >= 20 else { return nil }

        // Verify magic cookie
        guard data[4] == 0x21, data[5] == 0x12, data[6] == 0xa4, data[7] == 0x42 else { return nil }
        // Verify transaction ID
        guard Array(data[8..<20]) == txID else { return nil }

        let msgLen = Int(data[2]) << 8 | Int(data[3])
        guard data.count >= 20 + msgLen else { return nil }

        // Walk attributes
        var pos = 20
        while pos + 4 <= 20 + msgLen {
            let attrType = Int(data[pos]) << 8 | Int(data[pos + 1])
            let attrLen  = Int(data[pos + 2]) << 8 | Int(data[pos + 3])
            pos += 4
            guard pos + attrLen <= data.count else { break }

            // 0x0020 = XOR-MAPPED-ADDRESS, 0x0001 = MAPPED-ADDRESS
            if attrType == 0x0020, attrLen >= 8 {
                // family byte at pos+1: 0x01 = IPv4
                guard data[pos + 1] == 0x01 else { pos += alignedLen(attrLen); continue }
                let b0 = data[pos + 4] ^ 0x21
                let b1 = data[pos + 5] ^ 0x12
                let b2 = data[pos + 6] ^ 0xa4
                let b3 = data[pos + 7] ^ 0x42
                return "\(b0).\(b1).\(b2).\(b3)"
            }
            if attrType == 0x0001, attrLen >= 8, data[pos + 1] == 0x01 {
                return "\(data[pos+4]).\(data[pos+5]).\(data[pos+6]).\(data[pos+7])"
            }
            pos += alignedLen(attrLen)
        }
        return nil
    }

    private static func alignedLen(_ n: Int) -> Int { (n + 3) & ~3 }
}

// Thread-safe one-shot flag
private final class AtomicFlag: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()
    /// Returns true the first time it is called; false on all subsequent calls.
    func set() -> Bool {
        lock.withLock {
            guard !value else { return false }
            value = true
            return true
        }
    }
}
