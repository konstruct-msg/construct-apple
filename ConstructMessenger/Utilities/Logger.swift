//
//  Logger.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//  Updated on 31.01.2026 - Added file logging
//  2026-07-26: Log.debug is DEBUG-only + @autoclosure (encoding/CPU audit E13)
//

import Foundation
import os.log

struct Log {
    private static func log(level: OSLogType, category: String, message: String) {
        let logger = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "cc.konstruct.messenger", category: category)
        os_log("%@", log: logger, type: level, message)

        // Also write to file if enabled (DEBUG / INTERNAL_TOOLS only — see LogCollector).
        let levelString: String
        switch level {
        case .debug: levelString = "DEBUG"
        case .info: levelString = "INFO"
        case .error: levelString = "ERROR"
        case .fault: levelString = "FAULT"
        default: levelString = "DEFAULT"
        }

        LogCollector.shared.append(level: levelString, category: category, message: message)
    }

    /// Debug diagnostics. **No-op in Release**: message is not evaluated (`@autoclosure`),
    /// so hex previews / string builds on encrypt-decrypt paths cost nothing in App Store builds.
    /// Only `debug` uses `@autoclosure` — `info`/`error` stay eager so actor-isolated
    /// interpolations (e.g. `TransportRouter.state`) keep valid isolation.
    static func debug(_ message: @autoclosure () -> String, category: String = "Default") {
        #if DEBUG
        log(level: .debug, category: category, message: message())
        #endif
    }

    static func info(_ message: String, category: String = "Default") {
        log(level: .info, category: category, message: message)
    }

    static func error(_ message: String, category: String = "Default") {
        log(level: .error, category: category, message: message)
    }

    static func fault(_ message: String, category: String = "Default") {
        log(level: .fault, category: category, message: message)
    }
}
