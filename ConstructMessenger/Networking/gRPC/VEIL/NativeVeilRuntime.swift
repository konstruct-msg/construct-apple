//
//  NativeVeilRuntime.swift
//  Construct Messenger
//
//  Production `VeilProxyRuntime` backed by the `libconstruct_core` C FFI.
//
//  Production path uses `veil_start` — the unified coordinator FFI that runs
//  parallel happy-eyeballs probing of obfs4 + WebTunnel inside Rust and returns
//  the winning method. The legacy per-method calls (`veil_proxy_start_*`) are
//  preserved for the test mock surface but no longer invoked from the app.
//

import Foundation

/// Production implementation of `VeilProxyRuntime` via `libconstruct_core` C FFI.
final class NativeVeilRuntime: VeilProxyRuntime {

    /// Rust `MethodSet` uses an inverted bitmask: set bit = disable method, zero bit = allow it.
    /// Mobile is veil-front-only, so every legacy method must be disabled here.
    static let veilFrontOnlyDisabledMethodsBitmask: UInt32 =
        (UInt32(1) << UInt32(VeilMethod.obfs4.rawValue))
        | (UInt32(1) << UInt32(VeilMethod.webTunnel.rawValue))
        | (UInt32(1) << UInt32(VeilMethod.masque.rawValue))

    /// Methods allowed into the Rust happy-eyeballs probe race. **veil-front only**.
    private static let allowedMethodsBitmask: UInt32 =
        veilFrontOnlyDisabledMethodsBitmask

    // MARK: - Unified coordinator path

    func startUnified(
        relay: VeilRelay,
        fingerprint: Data,
        scoresPath: String?
    ) -> Result<VeilStartOutcome, VeilProxyRuntimeError> {
        let address    = relay.address
        let bundle     = relay.bridgeLine
        let sni        = relay.tlsServerName ?? ""
        let spki       = relay.pinnedSpki ?? ""
        let hostHeader = relay.wtHostHeader ?? ""
        let wtPath     = relay.wtPath ?? ""
        // veil-front ticket is sent only when the feature flag is on AND the
        // relay actually carries a ticket. Empty string → Rust excludes
        // veil-front from the probe race (its ticket parse fails the probe).
        let veilFrontTicket = (VeilProxyStore.veilFrontEnabled ? relay.veilFrontTicket : nil) ?? ""

        // Diagnose veil_start=-1 failures by logging what we hand to Rust.
        // Empty bundle/SPKI/SNI are the most common causes of fail-before-network
        // (Rust returns -1 without ever attempting TCP).
        Log.info(
            "VEIL FFI start → addr='\(address)' " +
            "bundle.len=\(bundle.count) sni='\(sni)' " +
            "spki.len=\(spki.count) spki.pfx=\(String(spki.prefix(12))) hostHeader='\(hostHeader)' wtPath='\(wtPath)' " +
            "veilFrontTicket.len=\(veilFrontTicket.count) " +
            "fingerprint.len=\(fingerprint.count) scoresPath=\(scoresPath ?? "nil")",
            category: "VEIL"
        )

        var out = VeilStartResult(port: 0, method: 0, latency_ms: 0)
        let rc = address.withCString { addrPtr in
            bundle.withCString { bundlePtr in
                sni.withCString { sniPtr in
                    spki.withCString { spkiPtr in
                        hostHeader.withCString { hostPtr in
                            wtPath.withCString { wtPathPtr in
                                veilFrontTicket.withCString { ticketPtr in
                                    withScoresPath(scoresPath) { scoresPtr in
                                        fingerprint.withUnsafeBytes { fpBuf -> Int32 in
                                            let fpBase = fpBuf.bindMemory(to: UInt8.self).baseAddress
                                            let req = VeilStartRequest(
                                                relay_addr: addrPtr,
                                                bundle: bundlePtr,
                                                tls_sni: sniPtr,
                                                spki_hex: spkiPtr,
                                                host_header: hostPtr,
                                                wt_base_path: wtPathPtr,
                                                network_fingerprint: fpBase,
                                                network_fingerprint_len: fingerprint.count,
                                                allowed_methods: Self.allowedMethodsBitmask,
                                                scores_path: scoresPtr,
                                                veil_front_ticket_b64: ticketPtr
                                            )
                                            return veil_start(req, &out)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        guard rc == 0, out.port > 0 else {
            // Surface the real failing stage (Rust collapses everything to rc=-1).
            var errBuf = [CChar](repeating: 0, count: 256)
            let errLen = veil_last_error(&errBuf, errBuf.count)
            let reason = errLen > 0 ? String(cString: errBuf) : nil
            Log.error("VEIL FFI start failed rc=\(rc) port=\(out.port) → \(reason ?? "(no detail)")", category: "VEIL")
            return .failure(rc == 2 ? .networkUnreachable : .startFailed(code: rc, reason: reason))
        }
        let method = VeilMethod(rawValue: out.method) ?? .obfs4
        return .success(VeilStartOutcome(port: out.port, method: method, latencyMs: out.latency_ms))
    }

    // MARK: - Lifecycle

    func stop() {
        // Coordinator FFI: stops both the unified path and any legacy proxy.
        _ = veil_stop()
    }

    func isAlive() -> Bool {
        veil_is_alive() != 0
    }

    // MARK: - Legacy per-method API (mock surface only)

    func start(_ request: VeilTransportRequest) -> Result<UInt16, VeilProxyRuntimeError> {
        var port: UInt16 = 0
        let result: Int32

        switch request {
        case .webTunnel(let address, let sni, let spki, let hostHeader, let bridgeCert, let wtBasePath):
            result = address.withCString { addrPtr in
                sni.withCString { sniPtr in
                    spki.withCString { spkiPtr in
                        hostHeader.withCString { hostPtr in
                            bridgeCert.withCString { bridgeCertPtr in
                                wtBasePath.withCString { basePathPtr in
                                    veil_proxy_start_webtunnel(addrPtr, sniPtr, spkiPtr, hostPtr, bridgeCertPtr, basePathPtr, &port)
                                }
                            }
                        }
                    }
                }
            }

        case .tlsPinned(let bridgeLine, let address, let sni, let spki, let profile):
            result = bridgeLine.withCString { blPtr in
                address.withCString { addrPtr in
                    sni.withCString { sniPtr in
                        spki.withCString { spkiPtr in
                            profile.withCString { profPtr in
                                veil_proxy_start_tls_profiled(blPtr, addrPtr, sniPtr, spkiPtr, profPtr, &port)
                            }
                        }
                    }
                }
            }

        case .tlsUnpinned(let bridgeLine, let address, let sni):
            result = bridgeLine.withCString { blPtr in
                address.withCString { addrPtr in
                    sni.withCString { sniPtr in
                        veil_proxy_start_tls(blPtr, addrPtr, sniPtr, &port)
                    }
                }
            }

        case .plainObfs4(let bridgeLine, let address):
            result = bridgeLine.withCString { blPtr in
                address.withCString { addrPtr in
                    veil_proxy_start(blPtr, addrPtr, &port)
                }
            }
        }

        guard result == 0, port > 0 else {
            return .failure(result == 2 ? .networkUnreachable : .startFailed(code: result, reason: nil))
        }
        return .success(port)
    }

    func startSecondary(bridgeLine: String, address: String) -> Result<UInt16, VeilProxyRuntimeError> {
        var port: UInt16 = 0
        let result = bridgeLine.withCString { blPtr in
            address.withCString { addrPtr in
                veil_proxy_start(blPtr, addrPtr, &port)
            }
        }
        guard result == 0, port > 0 else {
            return .failure(result == 2 ? .networkUnreachable : .startFailed(code: result, reason: nil))
        }
        return .success(port)
    }

    // MARK: - Helpers

    /// Bridges an optional Swift String into a `UnsafePointer<CChar>?` for the C FFI.
    /// Passing NULL for `scores_path` makes Rust use an in-memory SQLite (no persistence).
    private func withScoresPath<R>(_ path: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
        guard let path else { return body(nil) }
        return path.withCString { body($0) }
    }
}
