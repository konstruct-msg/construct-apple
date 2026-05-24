//
//  NativeIceProxyRuntime.swift
//  Construct Messenger
//
//  Production `IceProxyRuntime` backed by the `libconstruct_core` C FFI.
//
//  All methods are synchronous and thread-safe: the underlying Rust statics
//  (`PROXY` and `PROXY_TLS`) are guarded by internal mutexes.
//

import Foundation

/// Production implementation of `IceProxyRuntime` via `libconstruct_core` C FFI.
final class NativeIceProxyRuntime: IceProxyRuntime {

    // MARK: - IceProxyRuntime

    func start(_ request: IceTransportRequest) -> Result<UInt16, IceProxyRuntimeError> {
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
                                    ice_proxy_start_webtunnel(addrPtr, sniPtr, spkiPtr, hostPtr, bridgeCertPtr, basePathPtr, &port)
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
                                ice_proxy_start_tls_profiled(blPtr, addrPtr, sniPtr, spkiPtr, profPtr, &port)
                            }
                        }
                    }
                }
            }

        case .tlsUnpinned(let bridgeLine, let address, let sni):
            result = bridgeLine.withCString { blPtr in
                address.withCString { addrPtr in
                    sni.withCString { sniPtr in
                        ice_proxy_start_tls(blPtr, addrPtr, sniPtr, &port)
                    }
                }
            }

        case .plainObfs4(let bridgeLine, let address):
            result = bridgeLine.withCString { blPtr in
                address.withCString { addrPtr in
                    ice_proxy_start(blPtr, addrPtr, &port)
                }
            }
        }

        guard result == 0, port > 0 else {
            return .failure(result == 2 ? .networkUnreachable : .startFailed(code: result))
        }
        return .success(port)
    }

    func startSecondary(bridgeLine: String, address: String) -> Result<UInt16, IceProxyRuntimeError> {
        var port: UInt16 = 0
        let result = bridgeLine.withCString { blPtr in
            address.withCString { addrPtr in
                ice_proxy_start(blPtr, addrPtr, &port)
            }
        }
        guard result == 0, port > 0 else {
            return .failure(result == 2 ? .networkUnreachable : .startFailed(code: result))
        }
        return .success(port)
    }

    func stop() {
        ice_proxy_stop()
    }

    func isAlive() -> Bool {
        ice_proxy_is_running() != 0
    }
}
