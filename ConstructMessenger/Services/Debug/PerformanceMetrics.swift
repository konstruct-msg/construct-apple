//
//  PerformanceMetrics.swift
//  Construct Messenger
//
//  Debug-only performance measurement for latency analysis.
//  All instrumentation is compiled out in Release builds.
//

import Foundation
import os.signpost

// MetricEvent must be defined in all build configs so call sites compile in Release.
// The Release PerformanceMetrics stubs are @inline(__always) no-ops — zero overhead.

// MARK: - Event Types

enum MetricEvent: String {
    // Message receive pipeline
    case envelopeArrived        = "envelope_arrived"
    case decryptStart           = "decrypt_start"
    case decryptEnd             = "decrypt_end"
    case uiDisplayed            = "ui_displayed"

    // Session
    case sessionInitStart       = "session_init_start"
    case sessionInitEnd         = "session_init_end"
    case sessionRestoreStart    = "session_restore_start"
    case sessionRestoreEnd      = "session_restore_end"

    // Core Data
    case coreDataSaveStart      = "core_data_save_start"
    case coreDataSaveEnd        = "core_data_save_end"
    case coreDataSaveFailed     = "core_data_save_failed"

    // Network
    case grpcConnectStart       = "grpc_connect_start"
    case grpcConnectEnd         = "grpc_connect_end"
    case veilProxyStartBegin     = "veil_proxy_start_begin"
    case veilProxyStartEnd       = "veil_proxy_start_end"
    case streamOpenStart        = "stream_open_start"
    case streamOpenEnd          = "stream_open_end"

    // Routing/failover
    case streamOpenFastFailover       = "stream_open_fast_failover"

    // Calls
    case callSetupStart         = "call_setup_start"
    case callSetupEnd           = "call_setup_end"
    case callSignalOpenStart    = "call_signal_open_start"
    case callSignalOpenEnd      = "call_signal_open_end"
}

#if DEBUG

// MARK: - Metric Record

struct MetricRecord: Identifiable {
    let id = UUID()
    let timestamp: CFAbsoluteTime
    let event: MetricEvent
    let label: String       // e.g. messageId or userId prefix
    let value: Double?      // optional precomputed duration in ms

    var formattedTime: String {
        let date = Date(timeIntervalSinceReferenceDate: timestamp)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
}

// MARK: - Latency Sample

struct LatencySample: Identifiable {
    let id = UUID()
    let label: String
    let durationMs: Double
    let timestamp: CFAbsoluteTime

    var formattedDuration: String {
        String(format: "%.1f ms", durationMs)
    }
}

// MARK: - Performance Metrics Collector

/// Thread-safe ring-buffer collector for debug performance events.
/// Use `PerformanceMetrics.shared` — all methods are no-ops in Release.
final class PerformanceMetrics: @unchecked Sendable {

    static let shared = PerformanceMetrics()
    private init() {}

    // Ring buffer — last 200 raw events
    private let lock = NSLock()
    private var events: [MetricRecord] = []
    private let maxEvents = 200

    // Computed latency samples (message receive end-to-end)
    private var latencySamples: [LatencySample] = []
    private let maxSamples = 100

    // Pending start times keyed by label (messageId, userId, etc.)
    private var pendingStarts: [String: (event: MetricEvent, time: CFAbsoluteTime)] = [:]

    // OSSignposter for Instruments integration
    private let signposter = OSSignposter(subsystem: "cc.konstruct.messenger", category: "Performance")

    // MARK: - Recording

    func record(_ event: MetricEvent, label: String = "", value: Double? = nil) {
        let now = CFAbsoluteTimeGetCurrent()
        let record = MetricRecord(timestamp: now, event: event, label: label, value: value)
        lock.lock()
        if events.count >= maxEvents { events.removeFirst() }
        events.append(record)
        lock.unlock()
    }

    /// Mark start of a paired operation. Call `end(_:label:)` to compute duration.
    func start(_ event: MetricEvent, label: String) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        pendingStarts["\(event.rawValue):\(label)"] = (event, now)
        lock.unlock()
        record(event, label: label)
    }

    /// Cancel a paired operation start without recording an end event.
    /// Used when the operation fails or is superseded (e.g., fast failover).
    func cancelStart(_ event: MetricEvent, label: String) {
        let key = "\(event.rawValue):\(label)"
        lock.lock()
        _ = pendingStarts.removeValue(forKey: key)
        lock.unlock()
    }

    /// Mark end of a paired operation. Returns duration in ms.
    @discardableResult
    func end(_ startEvent: MetricEvent, endEvent: MetricEvent, label: String) -> Double? {
        let now = CFAbsoluteTimeGetCurrent()
        let key = "\(startEvent.rawValue):\(label)"
        lock.lock()
        guard let start = pendingStarts.removeValue(forKey: key) else {
            lock.unlock()
            return nil
        }
        let durationMs = (now - start.time) * 1000
        lock.unlock()

        record(endEvent, label: label, value: durationMs)
        addSample(LatencySample(label: "\(startEvent.rawValue)→\(endEvent.rawValue) \(label)", durationMs: durationMs, timestamp: now))
        return durationMs
    }

    private func addSample(_ sample: LatencySample) {
        lock.lock()
        if latencySamples.count >= maxSamples { latencySamples.removeFirst() }
        latencySamples.append(sample)
        lock.unlock()
    }

    // MARK: - Convenience: message receive pipeline

    func messageEnvelopeArrived(messageId: String) {
        start(.envelopeArrived, label: messageId)
    }

    func messageDecryptStart(messageId: String) {
        start(.decryptStart, label: messageId)
    }

    func messageDecryptEnd(messageId: String) {
        end(.decryptStart, endEvent: .decryptEnd, label: messageId)
    }

    /// Call after message is inserted into CoreData (visible to UI).
    func messageUIDisplayed(messageId: String) {
        let durationMs = end(.envelopeArrived, endEvent: .uiDisplayed, label: messageId)
        if let ms = durationMs {
            let label = String(messageId.prefix(8))
            Log.debug("PERF msg=\(label)… receive→display: \(String(format: "%.1f", ms))ms", category: "Metrics")
        }
    }

    func coreDataSaveStart(label: String) {
        start(.coreDataSaveStart, label: label)
    }

    func coreDataSaveEnd(label: String) {
        end(.coreDataSaveStart, endEvent: .coreDataSaveEnd, label: label)
    }

    func coreDataSaveFailed(label: String) {
        cancelStart(.coreDataSaveStart, label: label)
        record(.coreDataSaveFailed, label: label)
    }

    // MARK: - Queries

    func allEvents() -> [MetricRecord] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func recentSamples(limit: Int = 20) -> [LatencySample] {
        lock.lock()
        defer { lock.unlock() }
        return Array(latencySamples.suffix(limit))
    }

    func averageLatency(for eventPair: String, last n: Int = 20) -> Double? {
        lock.lock()
        let relevant = latencySamples.filter { $0.label.hasPrefix(eventPair) }.suffix(n)
        lock.unlock()
        guard !relevant.isEmpty else { return nil }
        return relevant.map(\.durationMs).reduce(0, +) / Double(relevant.count)
    }

    func count(event: MetricEvent, last n: Int? = nil) -> Int {
        lock.lock()
        let slice = n == nil ? events[...] : events.suffix(n!)
        let count = slice.filter { $0.event == event }.count
        lock.unlock()
        return count
    }

    func p95Latency(for eventPair: String, last n: Int = 20) -> Double? {
        lock.lock()
        let relevant = latencySamples.filter { $0.label.hasPrefix(eventPair) }.suffix(n)
        lock.unlock()
        guard !relevant.isEmpty else { return nil }
        let sorted = relevant.map(\.durationMs).sorted()
        let idx = max(0, Int(Double(sorted.count) * 0.95) - 1)
        return sorted[idx]
    }

    func clearAll() {
        lock.lock()
        events.removeAll()
        latencySamples.removeAll()
        pendingStarts.removeAll()
        lock.unlock()
    }
}

// MARK: - OSSignposter integration

extension PerformanceMetrics {

    private static let spLog = OSLog(subsystem: "cc.konstruct.messenger", category: .pointsOfInterest)

    static func signpostBegin(_ name: StaticString, id: OSSignpostID = .exclusive) {
        os_signpost(.begin, log: spLog, name: name)
    }

    static func signpostEnd(_ name: StaticString) {
        os_signpost(.end, log: spLog, name: name)
    }

    static func signpostEvent(_ name: StaticString, format: StaticString = "", _ args: CVarArg...) {
        os_signpost(.event, log: spLog, name: name)
    }
}

#else

// MARK: - Release stubs (compile-out)

final class PerformanceMetrics: @unchecked Sendable {
    static let shared = PerformanceMetrics()
    private init() {}

    @inline(__always) func record(_ event: MetricEvent, label: String = "", value: Double? = nil) {}
    @inline(__always) func start(_ event: MetricEvent, label: String) {}
    @inline(__always) func cancelStart(_ event: MetricEvent, label: String) {}
    @discardableResult @inline(__always) func end(_ startEvent: MetricEvent, endEvent: MetricEvent, label: String) -> Double? { nil }
    @inline(__always) func messageEnvelopeArrived(messageId: String) {}
    @inline(__always) func messageDecryptStart(messageId: String) {}
    @inline(__always) func messageDecryptEnd(messageId: String) {}
    @inline(__always) func messageUIDisplayed(messageId: String) {}
    @inline(__always) func coreDataSaveStart(label: String) {}
    @inline(__always) func coreDataSaveEnd(label: String) {}
    @inline(__always) func coreDataSaveFailed(label: String) {}
    @inline(__always) func clearAll() {}
    @inline(__always) func count(event: MetricEvent, last n: Int? = nil) -> Int { 0 }
}

#endif
