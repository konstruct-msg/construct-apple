//
//  ContentTypeLiteralScanTests.swift
//  ConstructMessengerTests
//
//  A content type is spelled from the generated `Shared_Proto_Core_V1_ContentType`, never as a
//  number (AGENTS.md, "Content types are cross-client"). Until 2026-11-03 `ContentTypeRouting`
//  returned `28`, `23`, `24` with the name in a comment, and `SessionControlCodec` switched on
//  `case 25:` — a comment is not checked, so a renumbered or retired type would have kept
//  routing by the old byte in silence.
//

import XCTest

/// Lines where a content type is a bare integer: compared or assigned next to a `contentType`
/// name, or returned / matched inside a block that a `contentType` line opens (a `switch` on it,
/// a `var canonicalContentType`, a `func …ContentType…`). Comments are dropped first.
enum ContentTypeLiteralScan {
    private static let name = #"[cC]ontent_?[tT]ype(?!Raw)\w*"#
    private static let direct = try! NSRegularExpression(
        pattern: name + #"\s*(?::\s*\w+\s*)?(==|!=|=|:|\?\?)\s*(?:UInt8\(|Int\()?\d+\b"#
    )
    private static let opener = try! NSRegularExpression(pattern: name + #"[^{}]*\{\s*$"#)
    private static let literalArm = try! NSRegularExpression(pattern: #"\b(case|return)\s+\d+\b"#)

    static func hits(in source: String) -> [Int] {
        var out: [Int] = []
        var depth = 0
        var contextDepths: [Int] = []
        for (index, raw) in source.components(separatedBy: "\n").enumerated() {
            let code = raw.range(of: "//").map { String(raw[..<$0.lowerBound]) } ?? raw
            let line = code.replacingOccurrences(of: #""(?:[^"\\]|\\.)*""#, with: "\"\"", options: .regularExpression)
            let range = NSRange(line.startIndex..., in: line)
            let inContext = !contextDepths.isEmpty
            if direct.firstMatch(in: line, range: range) != nil
                || (inContext && literalArm.firstMatch(in: line, range: range) != nil) {
                out.append(index + 1)
            }
            if opener.firstMatch(in: line, range: range) != nil {
                contextDepths.append(depth)
            }
            depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            while let last = contextDepths.last, depth <= last { contextDepths.removeLast() }
        }
        return out
    }
}

final class ContentTypeLiteralScanTests: XCTestCase {

    func testTheScanSeesEachForm() {
        XCTAssertEqual(ContentTypeLiteralScan.hits(in: "if message.contentType == 13 { }"), [1])
        XCTAssertEqual(ContentTypeLiteralScan.hits(in: "static let heartbeatContentType: UInt8 = 13"), [1])
        XCTAssertEqual(ContentTypeLiteralScan.hits(in: "send(contentType: UInt8(28))"), [1])
        XCTAssertEqual(ContentTypeLiteralScan.hits(in: """
            var canonicalContentType: UInt8 {
                switch self {
                case .control: return 28
                }
            }
            func other() -> Int { return 3 }
            """), [3])
        XCTAssertEqual(ContentTypeLiteralScan.hits(in: """
            switch contentType {
            case 25: return .ping
            default: return nil
            }
            """), [2])
    }

    func testTheScanLeavesTheGeneratedSpellingAlone() {
        XCTAssertEqual(ContentTypeLiteralScan.hits(in: """
            static let heartbeatContentType = UInt8(Shared_Proto_Core_V1_ContentType.heartbeat.rawValue)
            switch Shared_Proto_Core_V1_ContentType(rawValue: contentType) {
            case .sessionPing: return .ping
            }
            let n = contentTypes.count // contentType == 28 in a comment
            Log.info("discarded (content_type=24)")
            if message.contentTypeRaw == 0 { }  // the local storage kind, another meaning
            """), [])
    }

    func testNoProductionSourceSpellsAContentTypeAsANumber() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        var scanned = 0
        var found: [String] = []
        for dir in ["ConstructMessenger", "Construct Desktop", "ConstructNotifications"] {
            let base = root.appendingPathComponent(dir)
            guard let walk = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
                return XCTFail("cannot walk \(dir)")
            }
            for case let url as URL in walk where url.pathExtension == "swift" {
                let path = url.path
                if path.contains("/Generated/") || url.lastPathComponent == "construct_core.swift" { continue }
                scanned += 1
                let source = try String(contentsOf: url, encoding: .utf8)
                for line in ContentTypeLiteralScan.hits(in: source) {
                    found.append("\(path.replacingOccurrences(of: root.path + "/", with: "")):\(line)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 300, "the walk found too few sources to mean anything")
        XCTAssertEqual(found, [], "spell these from Shared_Proto_Core_V1_ContentType")
    }
}
