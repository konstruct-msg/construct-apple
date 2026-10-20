//
//  SendJitter.swift
//  Construct Messenger
//
//  The short random delay before a message leaves, so its send time does not mirror the keystroke.
//  The core decides it (`recommended_send_delay_ms`), from the priority and the battery level.
//
//  Until 2026-10-20 this was `TrafficProtectionService`, the wrapper of the core's
//  `TrafficProtectionManager`: cover traffic — dummy messages on a schedule, a battery observer,
//  energy metrics and a DEBUG switch. No dummy was ever sent (the send was a stub and the scheduler
//  off in release), and the owner retired it for its network and battery cost; core 0.55.0 removed
//  the manager (`decisions/cover-traffic-retired.md`, TODO 202). Padding stays in the core.
//

import Foundation
#if os(iOS)
import UIKit
#endif

enum SendJitter {
    /// Milliseconds to wait before sending. `isHighPriority` is true for a message a person wrote.
    @MainActor
    static func delayMs(isHighPriority: Bool) -> UInt64 {
        recommendedSendDelayMs(isHighPriority: isHighPriority, batteryLevel: batteryLevel)
    }

    /// 0…1, or 1 when the platform does not say — the core's own assumption for an unknown level.
    @MainActor
    private static var batteryLevel: Float {
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        return level < 0 ? 1 : level
        #else
        return 1
        #endif
    }
}
