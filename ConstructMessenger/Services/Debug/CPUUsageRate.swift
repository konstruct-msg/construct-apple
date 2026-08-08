//
//  CPUUsageRate.swift
//  Construct Messenger
//
//  Process CPU as a rate between two cumulative samples.
//
//  WHY THIS REPLACED THE OLD READING (2026-08-08): `RuntimeDiagnostics` used to report
//  CPU as the sum of `thread_basic_info.cpu_usage` over all non-idle threads. That number
//  is not a measurement. `cpu_usage` is an exponentially decayed average the scheduler keeps
//  per thread, each over its own recent window; summing such values does not correspond to
//  anything on a clock, and it grows with the number of live threads — which is exactly what
//  rises when the app comes to the foreground and opens QUIC, gRPC and SwiftUI work. It read
//  52% in the background and 190% in the foreground on every session of 2026-08-08, and there
//  was no way to tell how much of that gap was load and how much was thread count.
//
//  Cumulative CPU time divided by elapsed monotonic time has neither problem: it is the
//  definition of the quantity, it cannot be inflated by thread count, and it is exact.
//
//  The per-thread `cpu_usage` value still has one honest use — *ranking* threads against each
//  other within one instant, to name which one is hot. It is used for that and nothing else.
//

import Foundation

enum CPUUsageRate {
    /// Two monotonically-increasing counters read at the same instant.
    struct Sample: Equatable {
        /// Total user + system CPU seconds burned by the process since launch, across both
        /// live and already-terminated threads.
        let cpuSeconds: Double
        /// Monotonic clock, so a wall-clock adjustment mid-interval cannot distort the rate.
        let uptimeSeconds: Double
    }

    /// Percent of a single core over the interval: 190% is roughly two cores busy throughout.
    ///
    /// Returns nil rather than a plausible-looking number when the interval cannot answer the
    /// question — no previous sample, no elapsed time, or counters that moved backwards. A
    /// `n/a` in the log is a fact; a fabricated 0.0% would be read as "idle" and believed.
    static func percent(from previous: Sample, to current: Sample) -> Double? {
        let elapsed = current.uptimeSeconds - previous.uptimeSeconds
        guard elapsed > 0 else { return nil }

        let burned = current.cpuSeconds - previous.cpuSeconds
        // Counters are cumulative and must never decrease. If they do, something is wrong with
        // the reading itself — report nothing rather than a negative CPU percentage.
        guard burned >= 0 else { return nil }

        return burned / elapsed * 100.0
    }
}
