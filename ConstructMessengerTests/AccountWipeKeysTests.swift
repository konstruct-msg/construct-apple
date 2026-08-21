//
//  AccountWipeKeysTests.swift
//  Construct MessengerTests
//
//  The list that must not drift again.
//

import XCTest
@testable import Construct_Messenger

final class AccountWipeKeysTests: XCTestCase {

    /// Repo root, derived from this file's compile-time path.
    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)      // …/ConstructMessengerTests/AccountWipeKeysTests.swift
            .deletingLastPathComponent()     // …/ConstructMessengerTests
            .deletingLastPathComponent()     // repo root
            .appendingPathComponent("ConstructMessenger")
    }

    /// Every `"construct.*"` string literal in the app sources.
    ///
    /// Cached across the two tests that ask for it: the walk covers the whole source tree and the
    /// target runs in parallel clones, so doing it twice is load for nothing. Worth avoiding —
    /// `WithRetryTests` went red once on the run that introduced this file (it reports a
    /// cancellation as the operation's own failure) and passed 3/3 alone afterwards.
    private static var cachedKeys: Set<String>?

    private func declaredConstructKeys() throws -> Set<String> {
        if let cached = Self.cachedKeys { return cached }
        let scanned = try scanConstructKeys()
        Self.cachedKeys = scanned
        return scanned
    }

    private func scanConstructKeys() throws -> Set<String> {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: sourceRoot, includingPropertiesForKeys: nil) else {
            throw XCTSkip("app sources not reachable from \(sourceRoot.path)")
        }
        let literal = try NSRegularExpression(pattern: #""(construct\.[A-Za-z0-9_.]+)""#)
        var keys: Set<String> = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            // Generated bindings hold no app keys and are megabytes of noise.
            if url.lastPathComponent == "construct_core.swift" { continue }
            if url.path.contains("/Generated/") { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in literal.matches(in: text, range: range) {
                if let r = Range(match.range(at: 1), in: text) { keys.insert(String(text[r])) }
            }
        }
        return keys
    }

    /// The defect this file exists for, stated as a rule: a key nobody classified is a key nobody
    /// decided about, and the two omissions that cost a week — `construct.stream.cursor` and
    /// `construct.session.vanishedPeers` — were both of exactly that kind. Adding a store now
    /// fails here until someone says whether a wipe removes it.
    func testEveryConstructKeyIsClassified() throws {
        let declared = try declaredConstructKeys()
        try XCTSkipIf(declared.isEmpty, "no sources scanned — the test would pass vacuously")

        let classified = Set(AccountWipeKeys.wiped)
            .union(AccountWipeKeys.survives)
            .union(AccountWipeKeys.wipedPrefixes)

        let unclassified = declared.filter { key in
            !classified.contains(key) &&
            !AccountWipeKeys.wipedPrefixes.contains { key.hasPrefix($0) }
        }

        XCTAssertTrue(
            unclassified.isEmpty,
            "unclassified UserDefaults keys — add each to AccountWipeKeys.wiped or .survives with a reason:\n"
                + unclassified.sorted().joined(separator: "\n")
        )
    }

    /// The scan must actually find keys. Without this the test above passes when the path is
    /// wrong, which is the shape of vacuous pass this repo has already paid for once.
    func testTheScanFindsTheKeysWeKnowExist() throws {
        let declared = try declaredConstructKeys()
        XCTAssertTrue(declared.contains("construct.stream.cursor"))
        XCTAssertTrue(declared.contains("construct.session.vanishedPeers"))
        XCTAssertGreaterThan(declared.count, 30, "the app owns ~53 construct.* keys")
    }

    /// A key cannot be both removed and kept.
    func testNoKeyIsInBothLists() {
        let both = Set(AccountWipeKeys.wiped).intersection(AccountWipeKeys.survives)
        XCTAssertTrue(both.isEmpty, "contradictory classification: \(both.sorted())")
    }

    // MARK: - The wipe itself

    func testWipeRemovesTheStreamCursor() {
        let defaults = UserDefaults(suiteName: "wipe-\(UUID().uuidString)")!
        defaults.set("1785495484579-0", forKey: "construct.stream.cursor")

        AccountWipeKeys.wipe(defaults)

        XCTAssertNil(
            defaults.string(forKey: "construct.stream.cursor"),
            "the omission that made every clean start resume from the old watermark"
        )
    }

    /// Families are swept by prefix — one entry per contact or message, and no list could name them.
    func testWipeSweepsPerContactFamilies() {
        let defaults = UserDefaults(suiteName: "wipe-\(UUID().uuidString)")!
        defaults.set(true, forKey: "construct.contact_request_seen.abc-123")
        defaults.set(Data(), forKey: "construct.outgoingWirePayload.5b1d7b0c-c0")

        AccountWipeKeys.wipe(defaults)

        XCTAssertNil(defaults.object(forKey: "construct.contact_request_seen.abc-123"))
        XCTAssertNil(defaults.object(forKey: "construct.outgoingWirePayload.5b1d7b0c-c0"))
    }

    /// And it must leave the device's own settings alone — a wipe changes identity, not hardware.
    func testWipeKeepsDeviceLevelSettings() {
        let defaults = UserDefaults(suiteName: "wipe-\(UUID().uuidString)")!
        defaults.set("https://example.invalid", forKey: "customServerURL")
        defaults.set(Data([1, 2, 3]), forKey: "construct.bundle_signing_key")

        AccountWipeKeys.wipe(defaults)

        XCTAssertEqual(defaults.string(forKey: "customServerURL"), "https://example.invalid")
        XCTAssertNotNil(defaults.data(forKey: "construct.bundle_signing_key"))
    }
}
