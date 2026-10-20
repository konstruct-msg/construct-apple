//
//  MediaLoaderTests.swift
//  ConstructMessengerTests
//
//  The state machine behind the media views' download-and-decrypt: a cache hit never fetches,
//  success stores and reports loaded, failure reports why and can be run again.
//

import GRPCCore
import XCTest
@testable import Construct_Messenger

@MainActor
final class MediaLoaderTests: XCTestCase {

    private typealias Loader = MediaLoader<String>

    private let descriptor = Loader.Descriptor(item: [
        "mediaId": "0123456789abcdef", "mediaUrl": "https://example.invalid/m",
        "mediaKey": Data(repeating: 7, count: 32).base64EncodedString(), "size": 100,
    ])!

    private struct Boom: Error {}

    private func makeLoader(
        pacing: Loader.Pacing = .init(),
        fetch: @escaping Loader.Fetch
    ) -> Loader {
        Loader(pacing: pacing, logCategory: "MediaLoaderTests", logLabel: "Test", fetch: fetch)
    }

    func testDescriptorNeedsAllThreeFieldsAndReadsSize() {
        XCTAssertNil(Loader.Descriptor(item: ["mediaId": "a", "mediaUrl": "b"]))
        XCTAssertNil(Loader.Descriptor(item: ["mediaId": "a", "mediaUrl": "b", "mediaKey": "!!not base64!!"]))
        XCTAssertEqual(descriptor.size, 100)
        XCTAssertEqual(descriptor.mediaKey.count, 32)
    }

    func testCacheHitMakesNoFetchAndNoStore() async {
        var fetches = 0
        var stores = 0
        let loader = makeLoader { _, _, _, _ in fetches += 1; return Data() }

        let value = await loader.load(
            descriptor, cached: { "cached" }, decode: { _ in "decoded" }, store: { _ in stores += 1 })

        XCTAssertEqual(value, "cached")
        XCTAssertEqual(fetches, 0)
        XCTAssertEqual(stores, 0)
        XCTAssertEqual(loader.value, "cached")
        XCTAssertFalse(loader.isLoading)
    }

    func testSuccessDecodesStoresAndReportsLoaded() async {
        var stored: [String] = []
        var fetchedId: String?
        let loader = makeLoader { id, _, _, _ in fetchedId = id; return Data("abc".utf8) }

        let value = await loader.load(
            descriptor,
            cached: { nil },
            decode: { String(decoding: $0, as: UTF8.self) },
            store: { stored.append($0) })

        XCTAssertEqual(value, "abc")
        XCTAssertEqual(stored, ["abc"])
        XCTAssertEqual(fetchedId, descriptor.mediaId)
        XCTAssertEqual(loader.value, "abc")
        XCTAssertEqual(loader.progress, 1)
        XCTAssertTrue(loader.hasReceivedBytes)
        XCTAssertNil(loader.failure)
    }

    func testFailureReportsRetryableThenLoadAgainSucceeds() async {
        var attempts = 0
        var stores = 0
        let loader = makeLoader { _, _, _, _ in
            attempts += 1
            if attempts == 1 { throw Boom() }
            return Data("ok".utf8)
        }

        let first = await loader.load(
            descriptor, cached: { nil }, decode: { String(decoding: $0, as: UTF8.self) },
            store: { _ in stores += 1 })
        XCTAssertNil(first)
        guard case .retryable = loader.failure else { return XCTFail("expected .retryable, got \(loader.state)") }
        XCTAssertEqual(loader.progress, 0)
        XCTAssertFalse(loader.hasReceivedBytes)
        XCTAssertEqual(stores, 0, "a failed fetch must not write a cache")

        let second = await loader.load(
            descriptor, cached: { nil }, decode: { String(decoding: $0, as: UTF8.self) },
            store: { _ in stores += 1 })
        XCTAssertEqual(second, "ok")
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(stores, 1)
        XCTAssertNil(loader.failure)
    }

    func testBytesShowProgressAndAFailureTakesThemBack() async {
        var loader: Loader!
        var midFlight: (Double, Bool)?
        loader = makeLoader { _, _, _, onProgress in
            onProgress?(50)
            for _ in 0..<3 { await Task.yield() }
            midFlight = (loader.progress, loader.hasReceivedBytes)
            throw Boom()
        }
        _ = await loader.load(descriptor, cached: { nil }, decode: { _ in "x" }, store: { _ in })

        XCTAssertEqual(midFlight?.0, 0.5)
        XCTAssertEqual(midFlight?.1, true)
        XCTAssertFalse(loader.hasReceivedBytes, "a failed attempt must not leave a percentage behind")
        XCTAssertEqual(loader.progress, 0)
    }

    func testNotFoundIsPermanentlyUnavailable() async {
        let loader = makeLoader { _, _, _, _ in throw RPCError(code: .notFound, message: "gone") }
        _ = await loader.load(descriptor, cached: { nil }, decode: { _ in "x" }, store: { _ in })
        XCTAssertEqual(loader.failure?.isPermanentlyUnavailable, true)
    }

    func testUndecodableBytesFailWithoutStoring() async {
        var stores = 0
        let loader = makeLoader { _, _, _, _ in Data("junk".utf8) }
        let value = await loader.load(descriptor, cached: { nil }, decode: { _ in nil }, store: { _ in stores += 1 })
        XCTAssertNil(value)
        guard case .undecodable = loader.failure else { return XCTFail("expected .undecodable, got \(loader.state)") }
        XCTAssertEqual(stores, 0)
    }

    func testThrowingDecodeIsAFailureNotACrash() async {
        let loader = makeLoader { _, _, _, _ in Data() }
        let value = await loader.load(descriptor, cached: { nil }, decode: { _ in throw Boom() }, store: { _ in })
        XCTAssertNil(value)
        guard case .retryable = loader.failure else { return XCTFail("expected .retryable, got \(loader.state)") }
    }

    func testAfterDownloadPacingIsVisibleWhileDecoding() async {
        let loader = makeLoader(pacing: .init(cap: 0.9, afterDownload: 0.95)) { _, _, _, _ in Data() }
        var seen: Double?
        _ = await loader.load(
            descriptor, cached: { nil },
            decode: { _ in seen = loader.progress; return "v" }, store: { _ in })
        XCTAssertEqual(seen, 0.95)
    }

    func testSecondLoadWhileInFlightIsIgnored() async {
        var fetches = 0
        var loader: Loader!
        var nested: String?
        loader = makeLoader { [descriptor] _, _, _, _ in
            fetches += 1
            nested = await loader.load(descriptor, cached: { nil }, decode: { _ in "n" }, store: { _ in })
            return Data()
        }
        _ = await loader.load(descriptor, cached: { nil }, decode: { _ in "outer" }, store: { _ in })
        XCTAssertNil(nested)
        XCTAssertEqual(fetches, 1)
    }
}
