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
                self?.sample(reason: "thermal_state_changed", isElevated: true)
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
        let message = [
            "reason=\(reason)",
            "app=\(snapshot.appState)",
            "thermal=\(snapshot.thermalState)",
            "low_power=\(snapshot.lowPowerMode ? "on" : "off")",
            "cpu=\(snapshot.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "n/a")",
            "resident=\(snapshot.residentMB.map { "\($0)MB" } ?? "n/a")",
            "footprint=\(snapshot.footprintMB.map { "\($0)MB" } ?? "n/a")"
        ].joined(separator: " ")

        if isElevated || snapshot.thermalSeverity >= 2 {
            Log.error("RUNTIME \(message)", category: "Runtime")
        } else {
            Log.info("RUNTIME \(message)", category: "Runtime")
        }
    }
}

private struct Snapshot {
    let appState: String
    let thermalState: String
    let thermalSeverity: Int
    let lowPowerMode: Bool
    let cpuPercent: Double?
    let residentMB: UInt64?
    let footprintMB: UInt64?

    static func capture() -> Snapshot {
        let processInfo = ProcessInfo.processInfo
        return Snapshot(
            appState: appStateName(UIApplication.shared.applicationState),
            thermalState: thermalStateName(processInfo.thermalState),
            thermalSeverity: thermalSeverity(processInfo.thermalState),
            lowPowerMode: processInfo.isLowPowerModeEnabled,
            cpuPercent: cpuUsagePercent(),
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

    private static func cpuUsagePercent() -> Double? {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        let result = task_threads(mach_task_self_, &threadList, &threadCount)
        guard result == KERN_SUCCESS, let threadList else { return nil }

        defer {
            let size = vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threadList), size)
        }

        var total: Double = 0
        for index in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(THREAD_INFO_MAX)
            let infoResult = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(threadList[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            guard infoResult == KERN_SUCCESS else { continue }
            if (info.flags & TH_FLAGS_IDLE) == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
            }
        }
        return total
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
