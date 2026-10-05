//
//  LegacyBodyNeverShownTests.swift
//  ConstructMessengerTests
//
//  `Message.legacyBody` is the body the bubble parsers read — media, voice and files as JSON. It
//  reached the screen several times while it was called `displayText` (the edit banner on
//  2026-10-05, after copy, quote and search). The rename says what it is; this says where it may
//  be: a view reads it only to parse it. A line in a view that names it must either call a
//  parser or say `// parser input` and why. Anything a person reads is `readableText`.
//

import XCTest

final class LegacyBodyNeverShownTests: XCTestCase {

    /// Mutation: write `Text(message.legacyBody)` in any view.
    func testViewsReadTheLegacyBodyOnlyToParseIt() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ConstructMessengerTests
            .deletingLastPathComponent()   // repo root
        let roots = ["ConstructMessenger/Views", "Construct Desktop"].map { repo.appendingPathComponent($0) }
        var checked = 0
        var offenders: [String] = []
        for root in roots {
            let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in files where url.pathExtension == "swift" {
                let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
                for (index, line) in lines.enumerated() where line.contains("legacyBody") {
                    let code = line.trimmingCharacters(in: .whitespaces)
                    if code.hasPrefix("//") { continue }
                    checked += 1
                    if code.contains("parse") || code.contains("// parser input") { continue }
                    offenders.append("\(url.lastPathComponent):\(index + 1): \(code)")
                }
            }
        }
        XCTAssertGreaterThan(checked, 0, "found no use at all — the scan is looking in the wrong place")
        XCTAssertTrue(offenders.isEmpty, "show `readableText`, or mark a parser input:\n" + offenders.joined(separator: "\n"))
    }
}
