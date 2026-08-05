//
//  CrashDiagnosticsCollector.swift
//  Construct Messenger
//
//  Crash reports that reach us without going through App Store Connect.
//
//  TODO 40 — "the app sometimes crashes when leaving Logs & Diagnostics" — has been open since
//  2026-08-04 with no diagnosis, because the crash reports never arrive: TestFlight delivers only
//  a JSON blob of device metadata, with the payload withheld (the tester has not opted into
//  sharing analytics with the developer, and that consent is not ours to grant). Two inspections
//  of the suspect screens produced two theories and no evidence. The cost of a theory without
//  evidence is already recorded in TODO 33.
//
//  MetricKit hands the crash to *the app itself* on the next launch — call stack, exception type
//  and code, signal, termination reason — independent of that pipeline. It is first-party and
//  passive: no signal handlers, no exception hooks, nothing running inside a dying process.
//
//  Two ways in, deliberately:
//    · `didReceive(_:)` — the system's own delivery, at most once every 24h;
//    · `collectPastPayloads()` — MetricKit's retained window (up to 7 days), pulled when a tester
//      opens Diagnostics. Without this a crash reported today would not be shareable until
//      tomorrow, which on a 17-day schedule is most of the budget.
//
//  What this is NOT: production crash telemetry. There is no backend to send to, and the on-disk
//  store follows the file-logging rule in `LogCollector` — nothing is persisted in an App Store
//  build. What ships to users is the capture; what we can read is the TestFlight path.
//

import Foundation
#if canImport(MetricKit) && os(iOS)
import MetricKit
#endif

@MainActor
final class CrashDiagnosticsCollector: NSObject {
    static let shared = CrashDiagnosticsCollector()

    /// Crash reports live in the log directory so the existing share path carries them — a
    /// tester already knows how to send logs, and a second export flow is a second thing to
    /// explain in the middle of an incident.
    /// Path of the crash store. `nonisolated` and derived, not stored, because `LogCollector`
    /// assembles the share archive off the main actor and must not have to hop for a file check.
    nonisolated static var crashFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("crashes.log")
    }

    /// The store, if anything has been written. Consumed by `LogCollector`'s archive.
    nonisolated static var storedReportsURL: URL? {
        let url = crashFileURL
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private let crashFile: URL
    /// Signatures already written, so the same payload pulled from both entry points is stored once.
    private var recorded: Set<String> = []
    private static let recordedKey = "crash_diagnostics_recorded_v1"
    /// Bound the receipt file. A crash loop must not become a disk-space defect.
    private static let maxStoredReports = 20

    private override init() {
        crashFile = Self.crashFileURL
        recorded = Set(UserDefaults.standard.stringArray(forKey: Self.recordedKey) ?? [])
        super.init()
    }

    // MARK: - Lifecycle

    /// Subscribe at launch. Cheap and idempotent; a no-op where MetricKit does not exist
    /// (simulator delivers nothing, macOS Desktop is a different target).
    func start() {
#if canImport(MetricKit) && os(iOS)
        MXMetricManager.shared.add(self)
        Log.info("CrashDiagnostics: subscribed to MetricKit", category: "Diagnostics")
        // Sweep whatever the system already holds — a crash from before this build shipped the
        // subscriber is still in MetricKit's window and is exactly the one we are looking for.
        collectPastPayloads()
#endif
    }

    /// Pull MetricKit's retained diagnostic window (≤7 days) without waiting for the daily
    /// callback. Called from Diagnostics so "crashed just now → shared logs" actually works.
    func collectPastPayloads() {
#if canImport(MetricKit) && os(iOS)
        let past = MXMetricManager.shared.pastDiagnosticPayloads
        guard !past.isEmpty else { return }
        ingest(past, source: "past")
#endif
    }

    // MARK: - Ingest

#if canImport(MetricKit) && os(iOS)
    private func ingest(_ payloads: [MXDiagnosticPayload], source: String) {
        var newReports = 0
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                let report = Self.format(crash, payload: payload)
                let signature = Self.signature(for: crash, payload: payload)
                guard !recorded.contains(signature) else { continue }
                recorded.insert(signature)
                newReports += 1
                append(report)
                // Also into the ordinary log, so a reader who greps the shared archive for ERROR
                // finds the crash where they are already looking.
                Log.error(
                    "CRASH (MetricKit/\(source)): \(Self.headline(crash))",
                    category: "Diagnostics"
                )
                PerformanceMetrics.shared.record(.crashDiagnosticReceived, label: Self.metricLabel(crash))
            }
        }
        guard newReports > 0 else { return }
        trimRecordedIfNeeded()
        UserDefaults.standard.set(Array(recorded), forKey: Self.recordedKey)
        Log.info("CrashDiagnostics: stored \(newReports) new crash report(s) [\(source)]", category: "Diagnostics")
    }

    /// One line naming the crash, for the log stream and the metric.
    private static func headline(_ crash: MXCrashDiagnostic) -> String {
        var parts: [String] = []
        if let type = crash.exceptionType { parts.append("exceptionType=\(type)") }
        if let code = crash.exceptionCode { parts.append("exceptionCode=\(code)") }
        if let signal = crash.signal { parts.append("signal=\(signal)") }
        if let reason = crash.terminationReason { parts.append("termination=\(reason)") }
        let meta = crash.metaData
        parts.append("build=\(meta.applicationBuildVersion)")
        parts.append("os=\(meta.osVersion)")
        return parts.joined(separator: " ")
    }

    /// Low-cardinality label — the crash class, never a stack frame or an identifier.
    private static func metricLabel(_ crash: MXCrashDiagnostic) -> String {
        if let signal = crash.signal { return "signal\(signal)" }
        if let type = crash.exceptionType { return "exc\(type)" }
        return "unknown"
    }

    /// Stable identity for a report. The call stack is included because two crashes can share an
    /// exception type and differ entirely in where they happened — the whole question here.
    private static func signature(for crash: MXCrashDiagnostic, payload: MXDiagnosticPayload) -> String {
        let stack = String(data: crash.callStackTree.jsonRepresentation(), encoding: .utf8) ?? ""
        var hasher = Hasher()
        hasher.combine(payload.timeStampBegin)
        hasher.combine(headline(crash))
        hasher.combine(stack.count)
        hasher.combine(stack.prefix(2_000))
        return String(hasher.finalize(), radix: 16)
    }

    private static func format(_ crash: MXCrashDiagnostic, payload: MXDiagnosticPayload) -> String {
        let meta = crash.metaData
        let stack = String(data: crash.callStackTree.jsonRepresentation(), encoding: .utf8)
            ?? "<call stack unavailable>"
        return """
        ========================================
        CRASH REPORT (MetricKit)
        ========================================
        Window:        \(payload.timeStampBegin) → \(payload.timeStampEnd)
        App version:   \(meta.applicationBuildVersion)
        OS:            \(meta.osVersion)
        Device:        \(meta.deviceType)
        Region format: \(meta.regionFormat)
        \(headline(crash))
        Virtual memory region:
        \(crash.virtualMemoryRegionInfo ?? "<none>")
        Call stack (JSON):
        \(stack)
        ========================================

        """
    }
#endif

    // MARK: - Store

    private func append(_ report: String) {
        // Same rule as the message log: a privacy-first messenger persists nothing to disk in an
        // App Store build. A crash report carries no message content, but the invariant is about
        // *what we keep*, and weakening it quietly for a debugging convenience is how such rules die.
        guard LogCollector.shared.isEnabled else { return }
        guard let data = report.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: crashFile) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: crashFile, options: .atomic)
        }
    }

    /// Keep the dedupe set from growing without bound across a long install.
    private func trimRecordedIfNeeded() {
        guard recorded.count > Self.maxStoredReports else { return }
        recorded = Set(recorded.suffix(Self.maxStoredReports))
    }

    func clearStoredReports() {
        try? FileManager.default.removeItem(at: crashFile)
        recorded.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.recordedKey)
    }
}

#if canImport(MetricKit) && os(iOS)
extension CrashDiagnosticsCollector: MXMetricManagerSubscriber {
    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        Task { @MainActor in self.ingest(payloads, source: "delivered") }
    }

    /// Required by the protocol; we take no interest in the aggregate metric payloads (battery,
    /// launch time, disk writes). Left empty deliberately rather than absent, so the reason is
    /// visible: this subscriber exists for crashes only.
    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {}
}
#endif
