//
//  CPUUsageRateTests.swift
//  ConstructMessengerTests
//
//  2026-08-08: the device ran hot on every launch, and the number we were reading to explain it
//  was not a measurement. `RuntimeDiagnostics` summed `thread_basic_info.cpu_usage` — a decayed
//  per-thread average — across all live threads, so the total grew with thread count. It read
//  52% backgrounded and 185–199% foregrounded on five consecutive sessions, and there was no way
//  to tell load from thread count. Nothing could be concluded from a day of logs.
//
//  These pin the replacement: CPU seconds burned over monotonic seconds elapsed.
//

import XCTest
@testable import Construct_Messenger

final class CPUUsageRateTests: XCTestCase {

    private func sample(cpu: Double, uptime: Double) -> CPUUsageRate.Sample {
        CPUUsageRate.Sample(cpuSeconds: cpu, uptimeSeconds: uptime)
    }

    // MARK: - The quantity

    func testOneCoreFullyBusyIsOneHundredPercent() {
        let percent = CPUUsageRate.percent(
            from: sample(cpu: 10, uptime: 1000),
            to: sample(cpu: 40, uptime: 1030)
        )
        XCTAssertEqual(percent ?? 0, 100.0, accuracy: 0.001)
    }

    func testTwoCoresBusyReadsAsTwoHundredPercent() {
        // The value the old metric kept showing. Now it means something: 60 CPU-seconds burned
        // in 30 wall seconds really is two cores.
        let percent = CPUUsageRate.percent(
            from: sample(cpu: 0, uptime: 1000),
            to: sample(cpu: 60, uptime: 1030)
        )
        XCTAssertEqual(percent ?? 0, 200.0, accuracy: 0.001)
    }

    func testAnIdleProcessReadsZero() {
        let percent = CPUUsageRate.percent(
            from: sample(cpu: 12.5, uptime: 1000),
            to: sample(cpu: 12.5, uptime: 1030)
        )
        XCTAssertEqual(percent ?? -1, 0.0, accuracy: 0.001)
    }

    func testTheRateIsIndependentOfIntervalLength() {
        // Same load, sampled over 0.4s (a lifecycle event) and over 30s (the timer). The old
        // metric's answer depended on how many threads happened to be alive at the instant.
        let short = CPUUsageRate.percent(
            from: sample(cpu: 100, uptime: 500),
            to: sample(cpu: 100.6, uptime: 500.4)
        )
        let long = CPUUsageRate.percent(
            from: sample(cpu: 100, uptime: 500),
            to: sample(cpu: 145, uptime: 530)
        )
        XCTAssertEqual(short ?? 0, 150.0, accuracy: 0.001)
        XCTAssertEqual(long ?? 0, 150.0, accuracy: 0.001)
    }

    // MARK: - What must read n/a rather than a number

    func testNoElapsedTimeIsUnanswerable() {
        // Two lifecycle notifications in the same instant: there is no interval to divide by,
        // and a 0.0% here would be logged as "idle" and believed.
        XCTAssertNil(CPUUsageRate.percent(
            from: sample(cpu: 10, uptime: 1000),
            to: sample(cpu: 10, uptime: 1000)
        ))
    }

    func testTimeGoingBackwardsIsUnanswerable() {
        XCTAssertNil(CPUUsageRate.percent(
            from: sample(cpu: 10, uptime: 1030),
            to: sample(cpu: 20, uptime: 1000)
        ))
    }

    func testCpuCounterGoingBackwardsIsUnanswerable() {
        // Cumulative counters cannot decrease. If one does, the reading is broken — report
        // nothing rather than a negative percentage that looks like a fixed bug.
        XCTAssertNil(CPUUsageRate.percent(
            from: sample(cpu: 40, uptime: 1000),
            to: sample(cpu: 39, uptime: 1030)
        ))
    }

    // MARK: - Shape of the real thing

    func testSubSecondIntervalsStayPrecise() {
        // Lifecycle events fire fractions of a second apart; the arithmetic must not round to
        // something useless there.
        let percent = CPUUsageRate.percent(
            from: sample(cpu: 100.0, uptime: 500.00),
            to: sample(cpu: 100.05, uptime: 500.05)
        )
        XCTAssertEqual(percent ?? 0, 100.0, accuracy: 0.001)
    }

    func testLongIdleGapDilutesABurst() {
        // 5 CPU-seconds burned at foregrounding, then 10 minutes asleep: the 30s-timer reading
        // afterwards must not still be showing the burst. This is the property the decayed
        // average did not have.
        let percent = CPUUsageRate.percent(
            from: sample(cpu: 100, uptime: 1000),
            to: sample(cpu: 105, uptime: 1600)
        )
        XCTAssertEqual(percent ?? 0, 0.833, accuracy: 0.001)
    }
}
