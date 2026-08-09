#if os(iOS)
import Foundation
import UIKit
import Darwin.Mach

/// Lightweight runtime sampler for device-only heating/perf investigations.
/// Logs process health on key lifecycle transitions and on a low-frequency timer
/// while the app stays active in the foreground.
@MainActor
final class RuntimeDiagnostics {
    static let shared = RuntimeDiagnostics()

    private enum Config {
        static let sampleInterval: TimeInterval = 30
    }

    private var isStarted = false
    private var observers: [NSObjectProtocol] = []
    private var sampleTimer: Timer?
    /// Previous cumulative counters. CPU is a rate, so the first snapshot after launch has
    /// nothing to divide by and honestly reports `cpu=n/a`.
    private var lastCPUSample: CPUUsageRate.Sample?

    private init() {}

    func start() {
        guard !isStarted else { return }
        isStarted = true
        installObservers()

        Log.info("Runtime diagnostics started", category: "Runtime")
        sample(reason: "startup")

        if UIApplication.shared.applicationState == .active {
            startTimerIfNeeded()
        }
    }

    private func installObservers() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.startTimerIfNeeded()
                self?.sample(reason: "did_become_active")
            }
        })

        observers.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sample(reason: "will_resign_active")
                self?.stopTimer()
            }
        })

        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sample(reason: "did_enter_background")
                self?.stopTimer()
            }
        })

        observers.append(center.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sample(reason: "memory_warning", isElevated: true)
            }
        })

        observers.append(center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                // Not elevated: a thermal transition is a reading. `sample` escalates on its
                // own if the state reached is critical.
                self?.sample(reason: "thermal_state_changed")
            }
        })

        observers.append(center.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sample(reason: "power_state_changed")
            }
        })
    }

    private func startTimerIfNeeded() {
        guard sampleTimer == nil else { return }
        let timer = Timer(timeInterval: Config.sampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sample(reason: "foreground_tick")
            }
        }
        sampleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopTimer() {
        sampleTimer?.invalidate()
        sampleTimer = nil
    }

    private func sample(reason: String, isElevated: Bool = false) {
        let snapshot = Snapshot.capture()

        // The interval belongs in the line: 187% over 30s and 187% over 0.4s are different
        // claims, and the sampler fires on lifecycle events as well as on the timer.
        var cpuField = "n/a"
        if let current = snapshot.cpuSample {
            if let previous = lastCPUSample,
               let percent = CPUUsageRate.percent(from: previous, to: current) {
                let window = current.uptimeSeconds - previous.uptimeSeconds
                cpuField = String(format: "%.1f%% over=%.1fs", percent, window)
            }
            lastCPUSample = current
        }

        var message = [
            "reason=\(reason)",
            "app=\(snapshot.appState)",
            "thermal=\(snapshot.thermalState)",
            "low_power=\(snapshot.lowPowerMode ? "on" : "off")",
            "cpu=\(cpuField)",
            "resident=\(snapshot.residentMB.map { "\($0)MB" } ?? "n/a")",
            "footprint=\(snapshot.footprintMB.map { "\($0)MB" } ?? "n/a")"
        ].joined(separator: " ")

        if !snapshot.hotThreads.isEmpty {
            message += " hot=[\(snapshot.hotThreads.map(\.description).joined(separator: ", "))]"
        }

        // The transport runtime is the one that pins a worker at 100% (2026-08-09), and from the
        // app side it is opaque — `hot=` can name the thread but not what is on it. `conns` tests
        // whether connections accumulate; `tasks` separates one task that never yields from tasks
        // that are never reaped. Cheap: two atomics behind an FFI call, once per sample.
        message += " transport=\(transportRuntimeStats())"

        // A `serious` thermal state is a finding, not a failure, and logging it as an error made
        // 15 of the 18 ERROR lines in a device log not be errors. The severity is already in the
        // message (`thermal=serious`) and greps for it directly. Only a state nothing can be done
        // about — critical, or a memory warning — is escalated.
        if isElevated || snapshot.thermalSeverity >= 3 {
            Log.error("RUNTIME \(message)", category: "Runtime")
        } else {
            Log.info("RUNTIME \(message)", category: "Runtime")
        }
    }
}

/// One hot thread, as a share of the instantaneous total. Used to name a culprit, not to
/// quantify it — see `HotThread.sample`.
private struct HotThread {
    let name: String
    let share: Double

    var description: String { String(format: "%@:%.0f%%", name, share) }
}

private struct Snapshot {
    let appState: String
    let thermalState: String
    let thermalSeverity: Int
    let lowPowerMode: Bool
    let cpuSample: CPUUsageRate.Sample?
    let hotThreads: [HotThread]
    let residentMB: UInt64?
    let footprintMB: UInt64?

    static func capture() -> Snapshot {
        let processInfo = ProcessInfo.processInfo
        return Snapshot(
            appState: appStateName(UIApplication.shared.applicationState),
            thermalState: thermalStateName(processInfo.thermalState),
            thermalSeverity: thermalSeverity(processInfo.thermalState),
            lowPowerMode: processInfo.isLowPowerModeEnabled,
            cpuSample: cpuSample(),
            hotThreads: HotThread.sample(limit: 3),
            residentMB: bytesToMB(residentMemoryBytes()),
            footprintMB: bytesToMB(memoryFootprintBytes())
        )
    }

    private static func appStateName(_ state: UIApplication.State) -> String {
        switch state {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func thermalSeverity(_ state: ProcessInfo.ThermalState) -> Int {
        switch state {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        @unknown default: return 1
        }
    }

    private static func bytesToMB(_ bytes: UInt64?) -> UInt64? {
        guard let bytes else { return nil }
        return bytes / 1_048_576
    }

    private static func residentMemoryBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.resident_size)
    }

    private static func memoryFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }

    /// Cumulative CPU seconds burned by the whole process, paired with a monotonic clock.
    ///
    /// Both halves are needed: `MACH_TASK_BASIC_INFO` carries the time of threads that have
    /// already exited, `TASK_THREAD_TIMES_INFO` the time of the ones still alive. Reading only
    /// the second loses everything a finished thread burned — which, for a burst of work at
    /// foregrounding, is most of it.
    private static func cpuSample() -> CPUUsageRate.Sample? {
        var basic = mach_task_basic_info()
        var basicCount = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let basicResult = withUnsafeMutablePointer(to: &basic) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &basicCount)
            }
        }
        guard basicResult == KERN_SUCCESS else { return nil }

        var times = task_thread_times_info()
        var timesCount = mach_msg_type_number_t(
            MemoryLayout<task_thread_times_info>.size / MemoryLayout<natural_t>.size
        )
        let timesResult = withUnsafeMutablePointer(to: &times) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(timesCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &timesCount)
            }
        }
        guard timesResult == KERN_SUCCESS else { return nil }

        let cpuSeconds = seconds(basic.user_time) + seconds(basic.system_time)
                       + seconds(times.user_time) + seconds(times.system_time)

        return CPUUsageRate.Sample(
            cpuSeconds: cpuSeconds,
            uptimeSeconds: ProcessInfo.processInfo.systemUptime
        )
    }

    private static func seconds(_ time: time_value_t) -> Double {
        Double(time.seconds) + Double(time.microseconds) / 1_000_000.0
    }
}

extension HotThread {
    /// The `limit` busiest threads by name, as a share of the instant's total.
    ///
    /// This is the one honest use of `thread_basic_info.cpu_usage`: comparing threads against
    /// each other at a single instant. It is deliberately reported as a *share* rather than a
    /// percentage of a core — the underlying values are decayed averages and do not sum to a
    /// wall-clock quantity, so only their ordering means anything. The absolute number in the
    /// `cpu=` field comes from `CPUUsageRate`, never from here.
    static func sample(limit: Int) -> [HotThread] {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
              let threadList else { return [] }

        defer {
            let size = vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threadList), size)
        }

        var usageByName: [String: Double] = [:]
        var total: Double = 0

        for index in 0..<Int(threadCount) {
            var info = thread_extended_info()
            var infoCount = mach_msg_type_number_t(
                MemoryLayout<thread_extended_info>.size / MemoryLayout<natural_t>.size
            )
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(threadList[index], thread_flavor_t(THREAD_EXTENDED_INFO), $0, &infoCount)
                }
            }
            guard result == KERN_SUCCESS, (info.pth_flags & TH_FLAGS_IDLE) == 0 else { continue }

            let usage = Double(info.pth_cpu_usage)
            guard usage > 0 else { continue }
            total += usage
            // Pools name every worker identically; summing by name is what makes "which
            // subsystem" answerable instead of listing three anonymous workers.
            usageByName[name(of: info), default: 0] += usage
        }

        guard total > 0 else { return [] }

        return usageByName
            .map { HotThread(name: $0.key, share: $0.value / total * 100.0) }
            .sorted { $0.share > $1.share }
            .prefix(limit)
            .map { $0 }
    }

    /// `pth_name` is a fixed 64-byte C buffer; the main thread and most system pools leave it
    /// empty, which is itself informative — an unnamed hog is UIKit/SwiftUI or libdispatch.
    private static func name(of info: thread_extended_info) -> String {
        var raw = info.pth_name
        let name = withUnsafeBytes(of: &raw) { buffer -> String in
            guard let base = buffer.bindMemory(to: CChar.self).baseAddress else { return "" }
            return String(cString: base)
        }
        return name.isEmpty ? "unnamed" : name
    }
}
#else
@MainActor
final class RuntimeDiagnostics {
    static let shared = RuntimeDiagnostics()
    private init() {}
    func start() {}
}
#endif
