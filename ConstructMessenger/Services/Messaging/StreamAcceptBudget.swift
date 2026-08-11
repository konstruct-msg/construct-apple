//
//  StreamAcceptBudget.swift
//  Construct Messenger
//
//  How long a stream open gets to be accepted, given what this session already knows.
//
//  Stage 2 of decisions/no-client-side-network-learning, and it is not the shape that note
//  proposed. The plan there was to pre-warm a VEIL standby so promotion would be cheap. Measured
//  on device 2026-08-11, promotion is *already* cheap:
//
//      10:43:07  Transport: proxy start gen=1 (async)
//      10:43:07  VEIL: relay=api.divany-kresla.uk:443 method=veil-front port=49549 latency=468ms
//      10:43:51  VEIL: … latency=173ms
//
//  173–468 ms, inside the same second. Pre-warming would save a third of a second. That is not
//  where the time goes.
//
//  Where it goes is the *decision*. Every direct attempt burns its full accept budget — 2.0 s —
//  plus reconnect backoff, and the router needs failures to accumulate before it escalates. On the
//  measured network that is 2 s spent re-confirming something this session already established.
//
//  So the leash shortens instead. Once direct has failed in this session, a direct open gets
//  `streamOpenAcceptTimeoutStandby` (0.8 s) rather than 2.0 s — the constant that has existed
//  since 2026-05 for exactly this purpose and has never had a reader. An open network is
//  untouched: the first attempt of every session still gets the full budget.
//

import Foundation

enum StreamAcceptBudget {

    /// Seconds to wait for the server to accept a stream open.
    ///
    /// - `isFastUdp`: H3 / engine-QUIC. Fails fast by nature; its own tighter budget applies and
    ///   is not shortened further — a UDP path that is going to work answers in well under 1.5 s.
    /// - `usingVEIL`: traffic is going through the relay. Deliberately long (20 s): a gRPC
    ///   server-streaming handler may not flush headers until it has something to send, and the
    ///   relay adds a round-trip on top. Shortening this is what rotated healthy relays in 2026-05.
    /// - `directAlreadyFailedThisSession`: the direct path has already failed once here. The next
    ///   attempt is a re-check, not a first impression, and VEIL is under half a second away.
    static func timeout(
        isFastUdp: Bool,
        usingVEIL: Bool,
        directAlreadyFailedThisSession: Bool
    ) -> TimeInterval {
        if isFastUdp { return NetworkTiming.GRPC.streamOpenAcceptTimeoutH3 }
        if usingVEIL { return NetworkTiming.GRPC.streamOpenAcceptTimeoutVEIL }
        if directAlreadyFailedThisSession { return NetworkTiming.GRPC.streamOpenAcceptTimeoutStandby }
        return NetworkTiming.GRPC.streamOpenAcceptTimeout
    }
}
