import XCTest
@testable import Construct_Messenger

/// What the person typed does not go into a log line (2026-10-16). Beta builds write the log to a
/// file testers export and send us; it carried a queued message's first 30 characters, contact
/// names, @aliases and file names. A line may say a value is there (`Log.presence`) or how long it
/// is, never what it is.
final class LogContentTests: XCTestCase {

    /// Names of values that hold what a person typed or chose to name.
    private static let userContent = try! NSRegularExpression(
        pattern: #"\b(username|displayName|filename|fileName|caption|transcript|previewText|legacyBody|messageText|newUsername|urlString|absoluteString|normalized)\b|\.text\b(?!\s*\()"#
    )
    private static let logCall = try! NSRegularExpression(pattern: #"Log\.(info|error|fault|debug)\("#)
    private static let interpolation = try! NSRegularExpression(pattern: #"\\\(([^()]*(?:\([^()]*\)[^()]*)*)\)"#)

    /// Mutation: put `\(username)` back into any log line — this reddens.
    func testNoLogLineInterpolatesWhatThePersonTyped() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        var offenders: [String] = []
        for dir in ["ConstructMessenger", "Construct Desktop"] {
            guard let walker = FileManager.default.enumerator(at: root.appendingPathComponent(dir), includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                if url.lastPathComponent == "construct_core.swift" || url.path.contains("/Generated/") { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                for (n, line) in text.components(separatedBy: "\n").enumerated() {
                    let ns = line as NSString
                    guard Self.logCall.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil else { continue }
                    for m in Self.interpolation.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                        let expr = ns.substring(with: m.range(at: 1))
                        if expr.hasPrefix("Log.presence(") || expr.hasPrefix("Log.link(") || expr.contains(".count") || expr.contains(".isEmpty") { continue }
                        if Self.userContent.firstMatch(in: expr, range: NSRange(location: 0, length: (expr as NSString).length)) != nil {
                            offenders.append("\(url.lastPathComponent):\(n + 1): \\(\(expr))")
                        }
                    }
                }
            }
        }
        XCTAssertEqual(offenders, [], "log lines that carry user content")
    }

    /// A scanned invite went into a tester's log whole (2026-10-17). Ours keep scheme and host,
    /// anyone else's only the scheme; neither keeps the rest.
    /// Mutation: return `url.absoluteString` from `Log.link` — this reddens, and so does the scan
    /// above once a line logs `\(url.absoluteString)` again.
    func testALinkSaysWhereButNotWhat() {
        let invite = "konstruct://add?invite=Q0l2MQAFiDBvb6ptRPilh_IkCbUC1zUEjXEl"
        XCTAssertEqual(Log.link(invite), "konstruct://add +\(invite.count - "konstruct://add".count) chars")
        XCTAssertFalse(Log.link(invite).contains("Q0l2"))
        let universal = Log.link("https://konstruct.cc/i/Q0l2MQAFiDBvb6pt")
        XCTAssertTrue(universal.hasPrefix("https://konstruct.cc +"), universal)
        XCTAssertFalse(universal.contains("Q0l2"))
        let external = Log.link("https://example.org/private/page?x=1")
        XCTAssertEqual(external, "https link, 36 chars")
        XCTAssertEqual(Log.link("not a url with spaces"), "unparsed, 21 chars")
    }

    func testPresenceSaysOnlyWhetherAValueIsThere() {
        XCTAssertEqual(Log.presence("Alice"), "set")
        XCTAssertEqual(Log.presence(""), "none")
        XCTAssertEqual(Log.presence(nil), "none")
    }
}
