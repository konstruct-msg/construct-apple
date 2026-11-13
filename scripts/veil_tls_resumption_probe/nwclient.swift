// Two NWConnections in a row to 127.0.0.1:<port>, TLS options as
// VeilFrontExternalDialer.makeConnection sets them (min TLS 1.2, ALPN h2, SNI, a custom
// verify block). Keep the two in step when the dialer's options change.
// argv: port, mode — "default" (resumption left on) | "noresume" (the dialer's setting).
import Foundation
import Network
import Security

let port = UInt16(CommandLine.arguments[1])!
let mode = CommandLine.arguments[2]

func once(_ label: String) {
    let tls = NWProtocolTLS.Options()
    let o = tls.securityProtocolOptions
    sec_protocol_options_set_min_tls_protocol_version(o, .TLSv12)
    sec_protocol_options_add_tls_application_protocol(o, "h2")
    sec_protocol_options_set_tls_server_name(o, "relay.test")
    if mode == "noresume" { sec_protocol_options_set_tls_resumption_enabled(o, false) }
    let q = DispatchQueue(label: label)
    // The probe's server is self-signed; the dialer pins an SPKI here instead.
    sec_protocol_options_set_verify_block(o, { _, _, complete in complete(true) }, q)
    let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!,
                            using: NWParameters(tls: tls))
    let done = DispatchSemaphore(value: 0)
    conn.stateUpdateHandler = { st in
        switch st {
        case .ready:
            conn.send(content: Data("GET / HTTP/1.0\r\n\r\n".utf8), completion: .contentProcessed { _ in })
            // Read, so the post-handshake NewSessionTicket messages are processed.
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { conn.cancel(); done.signal() }
            }
        case .failed(let e), .waiting(let e):
            FileHandle.standardError.write(Data("\(label): \(e)\n".utf8))
            conn.cancel(); done.signal()
        default: break
        }
    }
    conn.start(queue: q)
    _ = done.wait(timeout: .now() + 10)
}

once("first")
Thread.sleep(forTimeInterval: 0.5)
once("second")
