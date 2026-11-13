import Foundation

/// A transcript whose layout does not settle, told apart from one that is being scrolled.
///
/// Desktop hung at 100 % CPU on opening one chat (owner, 2026-11-12): a `sample` of the main thread
/// spent five seconds inside a single `NSWindow` layout pass, with `onScrollGeometryChange` firing
/// on every round of it. The log had nothing — the app writes no line from inside a layout — so
/// the only evidence was the silence after `PIN arm reason=opening`. This is the line that was
/// missing: which geometry fields keep changing, and between which values.
///
/// A scroll changes the geometry once a frame, 120 times a second at most. A layout that feeds
/// itself changes it without waiting for a frame, thousands of times a second. The limit sits
/// well between the two.
struct TranscriptLayoutLoopDetector {
    /// Changes within `window` that no frame-paced scroll reaches.
    static let changeLimit = 400
    static let window: TimeInterval = 1
    /// Samples the report describes — enough to show a period-2 or period-3 oscillation.
    static let reportedSamples = 24

    private var stamps: [TimeInterval] = []
    private var samples: [ChatScrollGeometry] = []
    private(set) var hasReported = false

    /// Note one geometry change at `now` (seconds, monotonic). Returns the report the first time
    /// the rate passes `changeLimit`, and nil otherwise — once per detector, so a loop that runs
    /// for minutes writes one line.
    mutating func note(_ geometry: ChatScrollGeometry, at now: TimeInterval) -> String? {
        guard !hasReported else { return nil }
        stamps.append(now)
        stamps.removeAll { now - $0 > Self.window }
        samples.append(geometry)
        if samples.count > Self.reportedSamples {
            samples.removeFirst(samples.count - Self.reportedSamples)
        }
        guard stamps.count >= Self.changeLimit else { return nil }
        hasReported = true
        let span = now - (stamps.first ?? now)
        return "TRANSCRIPT_LAYOUT_LOOP: \(stamps.count) geometry changes in "
            + String(format: "%.2fs", span) + " — " + Self.describe(samples)
    }

    /// Each field over `samples`: the values it took, in order of first appearance, for the
    /// fields that changed; the one value for those that did not.
    static func describe(_ samples: [ChatScrollGeometry]) -> String {
        let fields: [(String, (ChatScrollGeometry) -> String)] = [
            ("distanceFromBottom", { points($0.distanceFromBottom) }),
            ("width", { points($0.width) }),
            ("contentFits", { $0.contentFits ? "true" : "false" }),
            ("contentHeight", { points($0.contentHeight) }),
            ("visibleMinY", { points($0.visibleMinY) }),
            ("containerHeight", { points($0.containerHeight) }),
            ("safeAreaBottom", { points($0.safeAreaBottom) }),
        ]
        var changing: [String] = []
        var steady: [String] = []
        for (name, value) in fields {
            var seen: [String] = []
            for sample in samples {
                let v = value(sample)
                if !seen.contains(v) { seen.append(v) }
            }
            if seen.count > 1 {
                changing.append("\(name){\(seen.joined(separator: ","))}")
            } else if let only = seen.first {
                steady.append("\(name)=\(only)")
            }
        }
        return "changing: " + (changing.isEmpty ? "none" : changing.joined(separator: " "))
            + "; steady: " + steady.joined(separator: " ")
    }

    private static func points(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }
}

/// Holds the detector outside SwiftUI's invalidation: it is written on every geometry change,
/// and as `@State` each write would itself be a change — inside the very loop it watches.
@MainActor
final class TranscriptLayoutLoopProbe {
    var detector = TranscriptLayoutLoopDetector()
}
