import Foundation
import Network

/// The spike's SDP exchange: one TCP connection, length-prefixed UTF-8 messages. Plaintext and
/// unauthenticated — anyone on the path can swap the DTLS fingerprint. Good enough to measure the
/// media path on a LAN; the product exchanges SDP inside the session, as calls do.
public final class Signalling {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "studio.signalling")

    private init(_ c: NWConnection) { connection = c }

    public static func listen(port: UInt16) async throws -> Signalling {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        return try await withCheckedThrowingContinuation { cont in
            var resumed = false
            listener.newConnectionHandler = { c in
                guard !resumed else { c.cancel(); return }
                resumed = true
                listener.cancel()
                let s = Signalling(c)
                c.stateUpdateHandler = { if case .ready = $0 { cont.resume(returning: s) } }
                c.start(queue: s.queue)
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let e) = state, !resumed { resumed = true; cont.resume(throwing: e) }
            }
            listener.start(queue: DispatchQueue(label: "studio.listener"))
        }
    }

    public static func connect(host: String, port: UInt16) async throws -> Signalling {
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let s = Signalling(c)
        return try await withCheckedThrowingContinuation { cont in
            var resumed = false
            c.stateUpdateHandler = { state in
                switch state {
                case .ready where !resumed: resumed = true; cont.resume(returning: s)
                case .failed(let e) where !resumed: resumed = true; cont.resume(throwing: e)
                case .waiting(let e) where !resumed: resumed = true; cont.resume(throwing: e)
                default: break
                }
            }
            c.start(queue: s.queue)
        }
    }

    public func send(_ text: String) async throws {
        var d = Data()
        let body = Data(text.utf8)
        var n = UInt32(body.count).bigEndian
        d.append(Data(bytes: &n, count: 4))
        d.append(body)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: d, completion: .contentProcessed { e in
                if let e { cont.resume(throwing: e) } else { cont.resume() }
            })
        }
    }

    public func receive() async throws -> String {
        let header = try await read(4)
        let n = header.reduce(0) { $0 << 8 | Int($1) }
        return String(decoding: try await read(n), as: UTF8.self)
    }

    private func read(_ n: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: n, maximumLength: n) { data, _, _, e in
                if let e { cont.resume(throwing: e) }
                else if let data, data.count == n { cont.resume(returning: data) }
                else { cont.resume(throwing: NWError.posix(.ECONNRESET)) }
            }
        }
    }

    public func close() { connection.cancel() }
}
