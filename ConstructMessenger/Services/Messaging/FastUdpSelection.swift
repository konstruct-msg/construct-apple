//
//  FastUdpSelection.swift
//  Construct Messenger
//
//  Which carrier the next MessageStream open uses, decided from four booleans and nothing else.
//
//  This replaces a persistent model of the world. Between 2026-08-08 and 2026-08-11 the choice was
//  made from a consecutive-failure counter, a ladder rung, a suppression window, a per-network
//  record persisted under a salted fingerprint, and a once-per-launch restore that read them back.
//  Every one of those five had a bug fixed in that same window, and the last two were written to
//  fix the first three. See decisions/no-client-side-network-learning.
//
//  The policy now: probe fast-UDP once per session and once per network change. If it fails, use
//  H2 for the rest of the session. Nothing is written down, so nothing has to be scoped to a
//  network, expired, restored, or evicted.
//

import Foundation

enum FastUdpSelection {

    /// Should this stream open skip fast-UDP (native H3 / engine-QUIC) and go straight to H2?
    ///
    /// - `h3Enabled` / `experimentalQuic`: the two feature flags that can supply a fast-UDP
    ///   carrier. With neither, there is nothing to choose.
    /// - `oneShotFallback`: `shouldFallbackToH2Direct` — the previous attempt asked for H2 on the
    ///   next open specifically. Consumed by the caller, not remembered here.
    /// - `failedThisSession`: fast-UDP already failed to open in this session. In memory, cleared
    ///   on a network path change, on an explicit transport toggle, and when QUIC delivers real
    ///   server data.
    static func useH2Fallback(
        h3Enabled: Bool,
        experimentalQuic: Bool,
        oneShotFallback: Bool,
        failedThisSession: Bool
    ) -> Bool {
        if !h3Enabled && !experimentalQuic { return true }
        return oneShotFallback || failedThisSession
    }
}
