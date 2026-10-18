//
//  PlayerSurfaceTests.swift
//  ConstructMessengerTests
//
//  Desktop aborted on the first video it opened: SwiftUI's `VideoPlayer` on macOS needs AVKit
//  loaded and nothing loaded it (TODO 158). `PlayerSurface` draws every video; this keeps it the
//  only place that does. The crash itself is macOS-only and this target runs on iOS, so the
//  guard is on the source.
//

import XCTest

final class PlayerSurfaceTests: XCTestCase {

    private static let videoPlayer = try! NSRegularExpression(pattern: #"(?<![A-Za-z_])VideoPlayer\("#)

    /// Mutation: put `VideoPlayer(player: player)` back into `MediaGalleryViewer` — this reddens.
    func testOnlyThePlayerSurfaceBuildsAVideoPlayer() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        var offenders: [String] = []
        var scanned = 0
        for dir in ["ConstructMessenger", "Construct Desktop"] {
            guard let walker = FileManager.default.enumerator(at: root.appendingPathComponent(dir), includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                scanned += 1
                if url.lastPathComponent == "PlayerSurface.swift" { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                for (n, line) in text.components(separatedBy: "\n").enumerated() {
                    let ns = line as NSString
                    if Self.videoPlayer.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil {
                        offenders.append("\(url.lastPathComponent):\(n + 1)")
                    }
                }
            }
        }
        XCTAssertGreaterThan(scanned, 100, "the scan found the sources")
        XCTAssertEqual(offenders, [], "use PlayerSurface: on macOS VideoPlayer aborts unless AVKit is loaded")
    }
}
