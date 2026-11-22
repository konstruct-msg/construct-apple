//
//  BackgroundAssertion.swift
//  Construct Messenger
//
//  Work that must finish after the person leaves the app — a media upload already under way —
//  runs under a UIKit background task, so iOS does not suspend the process and reclaim its sockets
//  (the VEIL listener among them) halfway through. Ended exactly once: by the work finishing, or by
//  iOS calling time, whichever comes first.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Begins and ends the system's background task; replaced in tests.
protocol BackgroundTaskHost: Sendable {
    /// Begin a task named `name`; `expired` runs if iOS calls time before it is ended.
    @MainActor func begin(_ name: String, expired: @escaping @MainActor @Sendable () -> Void) -> Int
    @MainActor func end(_ id: Int)
}

/// The app's own: `UIApplication`'s background tasks; nothing to hold on macOS, which does not
/// suspend a running app this way.
struct SystemBackgroundTaskHost: BackgroundTaskHost {
    @MainActor func begin(_ name: String, expired: @escaping @MainActor @Sendable () -> Void) -> Int {
        #if canImport(UIKit)
        UIApplication.shared.beginBackgroundTask(withName: name) { MainActor.assumeIsolated { expired() } }.rawValue
        #else
        0
        #endif
    }

    @MainActor func end(_ id: Int) {
        #if canImport(UIKit)
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: id))
        #endif
    }
}

enum BackgroundAssertion {
    /// `body` with the app kept running until it returns or throws. When iOS calls time first the
    /// task is ended then, and `body` carries on as long as the process does — its own failure
    /// handling (a retry) takes over.
    /// `body` runs on the caller's actor (`isolation`), as if called directly.
    static func run<T>(
        _ name: String,
        host: any BackgroundTaskHost = SystemBackgroundTaskHost(),
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let held = await Held(host: host, name: name)
        defer { Task { @MainActor in held.release() } }
        return try await body()
    }

    /// One begun task, released once.
    @MainActor
    private final class Held {
        private let host: any BackgroundTaskHost
        private var id: Int?

        init(host: any BackgroundTaskHost, name: String) {
            self.host = host
            id = nil
            id = host.begin(name) { [weak self] in self?.release() }
        }

        func release() {
            guard let id else { return }
            self.id = nil
            host.end(id)
        }
    }
}
