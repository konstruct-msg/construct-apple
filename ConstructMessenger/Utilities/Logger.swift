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
    private static func log(level: OSLogType, category: String, message raw: String) {
        // The one place a VEIL front's name is taken out of a line (`LogRedaction`, TODO 135).
        let message = LogRedaction.redact(raw)
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

    /// Whether a value the person typed is there — never the value. Names, @aliases, file names
    /// and message text are not log material: beta builds write the log to a file the tester
    /// sends us, and until 2026-10-16 it carried a queued message's first 30 characters, contact
    /// names and file names (`LogContentTests` holds the line).
    static func presence(_ value: String?) -> String {
        (value ?? "").isEmpty ? "none" : "set"
    }

    /// What a link may say in a log: our own links by scheme and host, anyone else's by scheme
    /// alone, and how long the rest is. The rest of ours carries an invite — the key material
    /// that adds the person as a contact — and a link tapped in a message is what was written
    /// (2026-10-17: a tester's exported log held a whole scanned invite).
    static func link(_ url: URL) -> String {
        let scheme = url.scheme ?? "?"
        let host = url.host ?? ""
        let ours = scheme == "konstruct" || host == "konstruct.cc" || host.hasSuffix(".konstruct.cc")
        let rest = url.absoluteString.count - scheme.count - 3 - (ours ? host.count : 0)
        return ours ? "\(scheme)://\(host) +\(max(0, rest)) chars" : "\(scheme) link, \(url.absoluteString.count) chars"
    }

    static func link(_ string: String) -> String {
        // A scanned code may be a bare compact invite, which `URL(string:)` happily accepts.
        guard let url = URL(string: string), url.scheme != nil else { return "unparsed, \(string.count) chars" }
        return link(url)
    }
}
