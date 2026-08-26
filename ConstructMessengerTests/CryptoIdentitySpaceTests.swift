//
//  CryptoIdentitySpaceTests.swift
//  ConstructMessengerTests
//
//  The guard the optional seam made possible.
//

import XCTest
@testable import Construct_Messenger

/// Nothing may name a peer to the crypto core except through `SessionAddressing`.
///
/// ## Why a source scan and not a runtime assertion
///
/// The defect this catches is a *new* call site, written by someone who did not know the seam
/// exists — and a runtime assertion only fires if a test happens to walk that line. Two of the
/// four defects the three-simulator stand caught on 2026-08-26 were exactly this: the orchestrator
/// door and the first-contact init path each handed the core an account id, both compiled, both
/// passed 1364 unit tests, and both produced a permanent AEAD failure on hardware.
///
/// The scan cannot be fooled by a value that merely *looks* resolved, because it does not reason
/// about values: it asks whether the argument came out of the seam, which is a syntactic question
/// with a syntactic answer. `AccountWipeKeysTests` established the technique in this target.
final class CryptoIdentitySpaceTests: XCTestCase {

    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConstructMessenger")
    }

    /// A call that hands an id to the core, and the file:line it sits on.
    private struct Site {
        let file: String
        let line: Int
        let text: String
    }

    /// Every `contactId:` argument passed to the Rust core or to the session Keychain.
    ///
    /// Deliberately narrow: `core.…(contactId:)`, `orchestratorCore?.…(contactId:)` and the
    /// `CfeIncomingEvent` constructors. Widening it to any `contactId:` anywhere would sweep in
    /// the app's own APIs, which speak the account space on purpose.
    private func coreFacingSites() throws -> [Site] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: sourceRoot, includingPropertiesForKeys: nil) else {
            throw XCTSkip("app sources not reachable from \(sourceRoot.path)")
        }
        let pattern = try NSRegularExpression(
            pattern: #"\b(?:core\??|orchestratorCore\??|CfeIncomingEvent)\s*\.\s*[A-Za-z]+\s*\(\s*contactId:\s*([^,)\n]+)"#
        )
        var sites: [Site] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            if url.lastPathComponent == "construct_core.swift" { continue }
            if url.path.contains("/Generated/") { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lines = text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                let range = NSRange(line.startIndex..., in: line)
                for match in pattern.matches(in: line, range: range) {
                    guard let r = Range(match.range(at: 1), in: line) else { continue }
                    sites.append(Site(file: url.lastPathComponent, line: index + 1,
                                      text: String(line[r]).trimmingCharacters(in: .whitespaces)))
                }
            }
        }
        return sites
    }

    /// The scan must find the calls we know exist. Without this the rule below passes whenever the
    /// regex stops matching — the shape of vacuous pass this repo has already paid for twice.
    func testTheScanFindsTheCallsWeKnowExist() throws {
        let sites = try coreFacingSites()
        XCTAssertGreaterThan(sites.count, 20, "the crypto layer makes ~35 core-facing calls")
        XCTAssertTrue(sites.contains { $0.file == "MessageCryptoService.swift" })
        XCTAssertTrue(sites.contains { $0.file == "CryptoManager.swift" })
    }

    /// **The rule.** An id reaching the core came out of `SessionAddressing`, or out of a local
    /// the compiler forced through it.
    ///
    /// An argument passes when it is a bare identifier: after the seam became optional, a bare
    /// local at one of these call sites can only exist because a `guard let` unwrapped it, and the
    /// only thing that produces one is `SessionAddressing`. An account id can no longer reach here
    /// by accident — it can only be written in on purpose, spelled out, which is what this reads.
    func testNothingNamesThePeerToTheCoreWithoutTheSeam() throws {
        let sites = try coreFacingSites()

        // Names that are known to hold an account id. A call site handing one of these straight to
        // the core is the defect: `message.from`, `userId`, `recipientId` and friends are the
        // account space by construction.
        let accountSpaced: Set<String> = [
            "userId", "recipientId", "peerUserId", "otherUserId", "message.from",
            "original.from", "user.id", "chat.otherUser?.id", "myUserId", "senderUserId",
            "currentUserId", "recipientUserId"
        ]

        let offenders = sites.filter { accountSpaced.contains($0.text) }
        XCTAssertTrue(
            offenders.isEmpty,
            "these hand the core an account id — resolve through SessionAddressing.contactId(forPeer:):\n"
                + offenders.map { "  \($0.file):\($0.line) — contactId: \($0.text)" }
                    .sorted().joined(separator: "\n")
        )
    }

    /// The seam is the only thing that produces a crypto identity, and it can fail. A call site
    /// that resolves inline would have to force-unwrap, which is how an account id would get back
    /// in — as a crash in release, or as `!` silently succeeding on a value that is not one.
    func testNoCallSiteForceUnwrapsTheSeam() throws {
        let sites = try coreFacingSites()
        let forced = sites.filter { $0.text.contains("SessionAddressing") && $0.text.contains("!") }
        XCTAssertTrue(
            forced.isEmpty,
            "force-unwrapped seam results:\n" + forced.map { "  \($0.file):\($0.line)" }.joined(separator: "\n")
        )
    }
}
