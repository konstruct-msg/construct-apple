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

    /// The core's tie-break has exactly one caller, and it is the seam.
    ///
    /// The rule is only worth exporting if both sides rank the same pair, and the pair is resolved
    /// in `SessionAddressing`. A second caller elsewhere would be one that resolved the ids itself
    /// — which is how the app came to rank two account ids against the core's two device ids, and
    /// neither implementation was wrong on its own.
    func testOnlyTheSeamAsksTheCoreForARole() throws {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: sourceRoot, includingPropertiesForKeys: nil) else {
            throw XCTSkip("app sources not reachable from \(sourceRoot.path)")
        }
        var callers: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            if url.lastPathComponent == "construct_core.swift" { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                guard line.contains("tieBreakRole(myId:") || line.contains("tieBreakRole(myId: ") else { continue }
                callers.append("\(url.lastPathComponent):\(index + 1)")
            }
        }
        XCTAssertFalse(callers.isEmpty, "the scan found no caller at all — the seam should be one")
        for caller in callers {
            XCTAssertTrue(caller.hasPrefix("SessionAddressing.swift:"),
                          "\(caller) asks the core for a role without resolving the pair at the seam")
        }
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
            "these hand the core an account id — expand it with SessionAddressing.deviceIds(ofPeer:in:):\n"
                + offenders.map { "  \($0.file):\($0.line) — contactId: \($0.text)" }
                    .sorted().joined(separator: "\n")
        )
    }

    // MARK: - Step 6: a peer is a set, and nobody picks from it

    /// Every `.swift` under the app, with its text. One walk for the scans below.
    private func appSources() throws -> [(name: String, path: String, text: String)] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: sourceRoot, includingPropertiesForKeys: nil) else {
            throw XCTSkip("app sources not reachable from \(sourceRoot.path)")
        }
        var out: [(String, String, String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            if url.lastPathComponent == "construct_core.swift" { continue }
            if url.path.contains("/Generated/") { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            out.append((url.lastPathComponent, url.path, text))
        }
        return out
    }

    /// **The device set is enumerated, never sampled.**
    ///
    /// `deviceIds(ofPeer:in:)` replaced a function that answered with one device, and the way to
    /// undo that replacement without noticing is to take `.first` of the set — which restores the
    /// old behaviour exactly, including its bug, while reading as if the set were being used. The
    /// order is deliberate and stable (`firstSeenAt`, then `deviceId`), so the first element is
    /// precisely the device the pin used to name.
    ///
    /// Required by step 6 of `decisions/a-peer-is-a-set-of-devices.md`.
    func testNobodyTakesOneDeviceOutOfThePeersSet() throws {
        var offenders: [String] = []
        for file in try appSources() {
            for (index, line) in file.text.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                guard line.contains("deviceIds(ofPeer:") || line.contains("devices(ofPeer:") else { continue }
                // `.first { … }` is a search through the set, not a pick of its head; `.first`
                // and `[0]` are the pick.
                let picks = line.contains(").first)") || line.contains(").first ")
                    || line.contains(").first?") || line.contains(").first,")
                    || line.contains(").first\n") || line.hasSuffix(").first")
                    || line.contains(")[0]") || line.contains(".first!")
                if picks { offenders.append("\(file.name):\(index + 1) — \(trimmed)") }
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "a peer's device set was sampled instead of walked — that is the pinned device again:\n"
                + offenders.sorted().joined(separator: "\n")
        )
    }

    /// **The crypto layer is handed a device; it does not go looking for one.**
    ///
    /// `pinnedDevice(ofPeer:)` is the offline single-device answer and has legitimate callers —
    /// the send tag, the control emitter, call signalling, the first-contact init fallback. What
    /// it may not do is sit under `encryptMessage`, `hasSession`, `archiveSession` or the
    /// background decrypt, where it silently chose one ratchet for every caller that held only an
    /// account. Step 6 took it out of these three files; this keeps it out.
    func testTheCryptoLayerDoesNotResolveThePeerItself() throws {
        let cryptoLayer: Set<String> = [
            "CryptoManager.swift", "CryptoManager+SessionArchive.swift", "MessageCryptoService.swift"
        ]
        var offenders: [String] = []
        for file in try appSources() where cryptoLayer.contains(file.name) {
            for (index, line) in file.text.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                if line.contains("pinnedDevice(ofPeer:") || line.contains("cryptoIdentity(ofUser:") {
                    offenders.append("\(file.name):\(index + 1) — \(trimmed)")
                }
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "the crypto layer resolved a peer to one device instead of being handed one:\n"
                + offenders.sorted().joined(separator: "\n")
        )
    }

    /// The scan above is only worth anything if the file set it names still exists.
    func testTheCryptoLayerFilesAreWhereTheScanLooks() throws {
        let names = Set(try appSources().map(\.name))
        for expected in ["CryptoManager.swift", "CryptoManager+SessionArchive.swift", "MessageCryptoService.swift"] {
            XCTAssertTrue(names.contains(expected), "\(expected) moved — the step 6 scan now guards nothing")
        }
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
