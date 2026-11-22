//
//  BackgroundAssertionTests.swift
//  ConstructMessengerTests
//
//  Work kept running after the person leaves the app (`BackgroundAssertion`): begun before the
//  work, ended once after it — on success, on a throw, or when iOS calls time first. And the media
//  upload runs under it. Each test names the mutation that must redden it.
//

import XCTest
@testable import Construct_Messenger

@MainActor
private final class RecordingHost: BackgroundTaskHost, @unchecked Sendable {
    var events: [String] = []
    var expire: (@MainActor @Sendable () -> Void)?

    func begin(_ name: String, expired: @escaping @MainActor @Sendable () -> Void) -> Int {
        events.append("begin \(name)")
        expire = expired
        return 7
    }

    func end(_ id: Int) { events.append("end \(id)") }
}

@MainActor
final class BackgroundAssertionTests: XCTestCase {

    /// The release is posted to the main actor after the work returns; give it the turn.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    /// Begun before the work runs, ended after it. Mutation: begin after the body, or never end —
    /// each reddens.
    func testTheTaskSpansTheWork() async {
        let host = RecordingHost()
        let value = await BackgroundAssertion.run("upload", host: host) { () async -> Int in
            host.events.append("work")
            return 42
        }
        await settle()
        XCTAssertEqual(value, 42)
        XCTAssertEqual(host.events, ["begin upload", "work", "end 7"])
    }

    /// A throw ends it too. Mutation: end only on success — this reddens.
    func testAThrowEndsItToo() async {
        struct Failed: Error {}
        let host = RecordingHost()
        do {
            _ = try await BackgroundAssertion.run("upload", host: host) { () async throws -> Int in throw Failed() }
            XCTFail("the throw goes through")
        } catch {}
        await settle()
        XCTAssertEqual(host.events, ["begin upload", "end 7"])
    }

    /// iOS calling time ends it then, and the work's own end does not end it again. Mutation: drop
    /// the once-guard — "end 7" twice.
    func testTimeCalledEndsItOnce() async {
        let host = RecordingHost()
        await BackgroundAssertion.run("upload", host: host) { () async -> Void in
            host.expire?()
            host.events.append("work went on")
        }
        await settle()
        XCTAssertEqual(host.events, ["begin upload", "end 7", "work went on"])
    }

    /// Every upload goes through `uploadWithRetry`; its transfer is the one held. Mutation: call
    /// `retryingTransfer` outside the assertion — this reddens.
    func testTheMediaUploadRunsUnderIt() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ConstructMessenger/Services/Media/MediaManager+Upload.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "static func uploadWithRetry("))
        let end = try XCTUnwrap(source.range(of: "static let maxTunnelWaits", range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound])
        let held = try XCTUnwrap(body.range(of: "BackgroundAssertion.run(\"media-upload\")"))
        let transfer = try XCTUnwrap(body.range(of: "try await retryingTransfer("))
        XCTAssertLessThan(held.lowerBound, transfer.lowerBound, "the transfer is inside the assertion")
    }
}
