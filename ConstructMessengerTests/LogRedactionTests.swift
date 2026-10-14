//
//  LogRedactionTests.swift
//  ConstructMessengerTests
//
//  A VEIL front's name never reaches a log in the clear (TODO 135,
//  decisions/veil-front-in-logs-is-a-keyed-label.md). The rule is tested as the pure function the
//  log calls; the simulator itself shows names (`LogRedaction.showsNames`), as an Xcode install does.
//

import XCTest
import CryptoKit
@testable import Construct_Messenger

final class LogRedactionTests: XCTestCase {

    private let key = SymmetricKey(data: Data(repeating: 0x42, count: 32))
    private let names: Set<String> = ["front.example.org", "cdn.example.net"]

    private func redact(_ line: String) -> String {
        LogRedaction.redact(line, names: names, key: key)
    }

    func testAFrontNameBecomesItsLabelWhereverItAppears() {
        let label = "front#\(LogRedaction.label("front.example.org", key: key))"
        XCTAssertEqual(redact("veil_start relay=front.example.org:443 ok"), "veil_start relay=\(label):443 ok")
        XCTAssertEqual(redact("TLS to FRONT.example.org failed"), "TLS to \(label) failed",
                       "case does not let a name through")
        XCTAssertFalse(redact("state=veilActive(relay: \"front.example.org:443\")").contains("example.org"),
                       "inside a state description too")
        XCTAssertFalse(redact("sni=cdn.example.net").contains("cdn.example.net"))
    }

    func testOneNameIsOneLabelAndTwoNamesTwo() {
        let a = LogRedaction.label("front.example.org", key: key)
        XCTAssertEqual(a, LogRedaction.label("Front.Example.org", key: key))
        XCTAssertNotEqual(a, LogRedaction.label("cdn.example.net", key: key))
        XCTAssertEqual(a.count, 8, "four bytes, hex")
    }

    /// A bare hash would let a censor hash the few candidates and compare.
    func testTheLabelDependsOnTheDeviceKey() {
        let other = SymmetricKey(data: Data(repeating: 0x43, count: 32))
        XCTAssertNotEqual(LogRedaction.label("front.example.org", key: key),
                          LogRedaction.label("front.example.org", key: other))
    }

    func testAnyIPv4ButLoopbackIsLabelled() {
        let out = redact("dial 203.0.113.7:443 via 127.0.0.1:55001")
        XCTAssertFalse(out.contains("203.0.113.7"))
        XCTAssertTrue(out.contains("ip#"))
        XCTAssertTrue(out.contains("127.0.0.1:55001"), "the local proxy port says nothing about the front")
    }

    func testALineWithNoFrontIsUntouched() {
        XCTAssertEqual(redact("stream connected in 120 ms, version 1.2.3"), "stream connected in 120 ms, version 1.2.3")
    }

    func testRegisteredCandidatesAreTakenByTheirHost() {
        XCTAssertEqual(LogRedaction.host(of: "front.example.org:443"), "front.example.org")
        XCTAssertEqual(LogRedaction.host(of: "Front.Example.org"), "front.example.org")
        XCTAssertNil(LogRedaction.host(of: "127.0.0.1:9050"))
        XCTAssertNil(LogRedaction.host(of: ""))
    }
}
