//
//  SafetyNumberConformanceTests.swift
//  ConstructMessengerTests
//
//  The safety number is the value two people read to each other to confirm no key was substituted.
//  It is now computed only by the core; this asserts that what arrives through the FFI is what the
//  cross-client vectors say — the same file every other client reads.
//
//  Why vectors and not a round-trip: a round-trip passes for any construction, including one that
//  has drifted from every other client. The failure this mechanism actually has is two
//  implementations that each behave consistently and disagree with each other, and its symptom is
//  two people staring at different numbers, concluding they are under attack, when nothing is.
//

import XCTest
@testable import Construct_Messenger

final class SafetyNumberConformanceTests: XCTestCase {

    private struct Vector: Decodable {
        let a: String
        let b: String
        let safetyNumber: String?
        let note: String?
        enum CodingKeys: String, CodingKey {
            case a, b, note
            case safetyNumber = "safety_number"
        }
    }

    private struct Vectors: Decodable {
        let vectors: [Vector]
        let refused: [Vector]
    }

    /// Located from this file rather than a bundle resource — adding a resource to the test target
    /// is a project-file change, and the fixture is vendored in the repo.
    private func loadVectors() throws -> Vectors {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repoRoot
            .appendingPathComponent("ConstructMessenger/Networking/gRPC/Generated/conformance")
            .appendingPathComponent("knst_safety_number.json")
        let loaded = try JSONDecoder().decode(Vectors.self, from: try Data(contentsOf: url))
        // An empty list makes every loop below vacuous, which is the failure the exercise exists
        // to avoid.
        XCTAssertGreaterThanOrEqual(loaded.vectors.count, 4, "vectors look truncated")
        XCTAssertGreaterThanOrEqual(loaded.refused.count, 5, "refusals look truncated")
        return loaded
    }

    /// Mutation: change the round count, the group width, or the sort in `crypto/recovery.rs` —
    /// every vector reddens, which is the loudest possible failure and therefore the safe one.
    func testTheNumberMatchesTheCrossClientVectors() throws {
        let loaded = try loadVectors()
        for v in loaded.vectors {
            guard let expected = v.safetyNumber else {
                XCTFail("vector \(v.a)/\(v.b) carries no expected value")
                continue
            }
            XCTAssertEqual(
                computeSafetyNumber(myDeviceId: v.a, theirDeviceId: v.b), expected,
                "\(v.note ?? "") — a change here is a change every client must make together"
            )
        }
    }

    /// Both sides must reach the same number, or every verification in the product fails.
    ///
    /// Mutation: drop the sort in the core — this reddens on the vectors whose ids sort the other
    /// way round, which is why the file carries one of each.
    func testWhoAsksDoesNotChangeTheAnswer() throws {
        for v in try loadVectors().vectors {
            XCTAssertEqual(
                computeSafetyNumber(myDeviceId: v.a, theirDeviceId: v.b),
                computeSafetyNumber(myDeviceId: v.b, theirDeviceId: v.a),
                "\(v.a.prefix(8))…/\(v.b.prefix(8))… depends on who is asking"
            )
        }
    }

    /// An id the core cannot read must produce **no** number.
    ///
    /// Until 2026-08-27 it produced one anyway, from bytes it substituted for the ones it could
    /// not decode — so every unreadable id collapsed onto the same value and two people who had
    /// verified nothing would have been shown a match. That is the failure a safety number exists
    /// to make impossible.
    ///
    /// Mutation: restore `unwrap_or_default()` in the core — every row here reddens.
    func testAnUnreadableIdProducesNoNumber() throws {
        for v in try loadVectors().refused {
            XCTAssertNil(
                computeSafetyNumber(myDeviceId: v.a, theirDeviceId: v.b),
                "\(v.note ?? "\(v.a)") produced a number it has no business producing"
            )
        }
    }

    /// The refusals must not merely be *equal to each other* — they must be absent. An earlier
    /// version of this bug had them all equal, which a naive "they differ from a good number"
    /// check would have passed.
    ///
    /// Mutation: have the core return `Some("")` instead of `None` — this reddens while the test
    /// above would not.
    func testRefusalIsAbsenceNotAValue() throws {
        let loaded = try loadVectors()
        let good = try XCTUnwrap(loaded.vectors.first)
        XCTAssertNotNil(computeSafetyNumber(myDeviceId: good.a, theirDeviceId: good.b))
        for v in loaded.refused {
            let produced = computeSafetyNumber(myDeviceId: v.a, theirDeviceId: v.b)
            XCTAssertNil(produced)
            XCTAssertNotEqual(produced, "", "an empty string is a value a UI will happily render")
        }
    }

    /// The view no longer carries an implementation, and nothing else may grow one: the core's
    /// function is the only caller-visible way to reach a safety number.
    ///
    /// Mutation: paste a second SHA-512 loop into any app source — this reddens.
    func testNothingInTheAppComputesItsOwn() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConstructMessenger")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw XCTSkip("app sources not reachable")
        }
        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            if url.lastPathComponent == "construct_core.swift" { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (i, line) in text.components(separatedBy: "\n").enumerated() {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("//") || t.hasPrefix("///") { continue }
                if line.contains("SHA512") || line.contains("1024") && line.contains("..<") {
                    offenders.append("\(url.lastPathComponent):\(i + 1) \(t.prefix(60))")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, "a second safety-number implementation:\n\(offenders.joined(separator: "\n"))")
    }
}
