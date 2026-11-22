//
//  MediaAutoDownloadPolicyTests.swift
//  ConstructMessengerTests
//
//  Media used to arrive only when the bubble appeared. That is fine for bandwidth and wrong for
//  durability: the server drops an object 7 days after upload, so a chat left unopened for a week
//  loses its photos permanently and the bubble shows a placeholder for something that was
//  delivered. Prefetch-on-arrival closes that, and this decides when it is allowed to.
//

import XCTest
@testable import Construct_Messenger

final class MediaAutoDownloadPolicyTests: XCTestCase {

    private let photo: Int64 = 2 * 1024 * 1024
    private let bigVideo: Int64 = 80 * 1024 * 1024

    private func shouldFetch(
        _ setting: MediaAutoDownloadSetting,
        size: Int64,
        expensive: Bool = false,
        constrained: Bool = false
    ) -> Bool {
        MediaAutoDownloadPolicy.shouldFetchOnArrival(
            setting: setting, sizeBytes: size, isExpensive: expensive, isConstrained: constrained
        )
    }

    // MARK: - Wi-Fi only must not cost anything on cellular

    /// On a metered connection "Wi-Fi only" behaves exactly as the app does with it off, so nobody's
    /// bill changes for choosing it. If this ever returns true, the option has quietly become a
    /// bandwidth decision made on the user's behalf.
    func testWiFiOnlyFetchesNothingOnCellular() {
        XCTAssertFalse(shouldFetch(.unmetered, size: photo, expensive: true))
    }

    /// Low Data Mode is an explicit instruction to hold back on speculative transfers, and it can
    /// be on over Wi-Fi. Reading only `isExpensive` would ignore it.
    func testLowDataModeIsRespectedEvenOnWiFi() {
        XCTAssertFalse(shouldFetch(.unmetered, size: photo, expensive: false, constrained: true))
    }

    func testWiFiOnlyFetchesAPhotoOnWiFi() {
        XCTAssertTrue(shouldFetch(.unmetered, size: photo))
    }

    /// A photo is bounded at 4 MB by MediaOptimizer; a transcoded clip is not. Pulling 80 MB
    /// because a message arrived is not what choosing Wi-Fi only means.
    func testWiFiOnlyDoesNotPullALargeVideoEvenOnWiFi() {
        XCTAssertFalse(shouldFetch(.unmetered, size: bigVideo))
    }

    func testTheSizeCeilingIsInclusive() {
        let ceiling = MediaAutoDownloadPolicy.unmeteredSizeCeiling
        XCTAssertTrue(shouldFetch(.unmetered, size: ceiling))
        XCTAssertFalse(shouldFetch(.unmetered, size: ceiling + 1))
    }

    // MARK: - The explicit choices

    /// `.always` is the user saying they would rather spend the bytes than lose the picture, so it
    /// overrides both the meter and the size ceiling. Anything less would make the option a lie.
    func testAlwaysMeansAlways() {
        XCTAssertTrue(shouldFetch(.always, size: bigVideo, expensive: true, constrained: true))
    }

    func testNeverMeansNever() {
        XCTAssertFalse(shouldFetch(.never, size: photo))
        XCTAssertFalse(shouldFetch(.never, size: 1))
    }

    // MARK: - Reading the setting

    /// A fresh install, or one that never chose, fetches nothing on arrival (owner 2026-11-22, vault
    /// todo 134): a fetch at delivery ties the object to the device it was delivered to.
    /// Mutation: the default back to `.unmetered` — this reddens.
    func testAnUnsetPreferenceFetchesNothingOnArrival() throws {
        let suite = "autodownload-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        XCTAssertEqual(MediaAutoDownloadSetting.default, .never)
        XCTAssertEqual(MediaAutoDownloadPolicy.current(defaults: defaults), .never)
    }

    /// Someone who chose Wi-Fi only before the default changed keeps it: the stored value is read
    /// first, the default only fills in an absent one.
    func testAChoiceStoredBeforeTheDefaultChangedIsKept() throws {
        let suite = "autodownload-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        defaults.set(MediaAutoDownloadSetting.unmetered.rawValue, forKey: MediaAutoDownloadSetting.defaultsKey)
        XCTAssertEqual(MediaAutoDownloadPolicy.current(defaults: defaults), .unmetered)
    }

    func testAStoredPreferenceIsHonoured() throws {
        let suite = "autodownload-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        defaults.set(MediaAutoDownloadSetting.never.rawValue, forKey: MediaAutoDownloadSetting.defaultsKey)
        XCTAssertEqual(MediaAutoDownloadPolicy.current(defaults: defaults), .never)
    }

    /// A value written by a future build (or a corrupted one) must not be read as some other
    /// setting by accident.
    func testAnUnknownStoredValueFallsBackToTheDefault() throws {
        let suite = "autodownload-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        defaults.set(99, forKey: MediaAutoDownloadSetting.defaultsKey)
        XCTAssertEqual(MediaAutoDownloadPolicy.current(defaults: defaults), MediaAutoDownloadSetting.default)
    }

    // MARK: - The wait before an arrival fetch

    /// Never sooner than 2 s: a fetch at the moment of delivery is the link the wait blurs.
    /// Mutation: a lower bound of 0 — this reddens.
    func testTheWaitIsNeverShorterThanTwoSeconds() {
        XCTAssertEqual(MediaAutoDownloadPolicy.prefetchDelay(fraction: 0), .seconds(2))
    }

    /// Never longer than 30 s: a photo in an open chat with auto-download on is not held up for long.
    /// Mutation: an upper bound of 300 s — this reddens.
    func testTheWaitIsNeverLongerThanThirtySeconds() {
        let longest = MediaAutoDownloadPolicy.prefetchDelay(fraction: 0.999_999)
        XCTAssertLessThanOrEqual(longest, .seconds(30))
        XCTAssertGreaterThan(longest, .seconds(29))
        for _ in 0..<1_000 {
            let wait = MediaAutoDownloadPolicy.prefetchDelay()
            XCTAssertTrue(wait >= .seconds(2) && wait <= .seconds(30), "\(wait)")
        }
    }

    /// The arrival fetch sleeps the drawn wait before it downloads.
    /// Mutation: drop the `Task.sleep(for: delay)` in `prefetch` — this reddens.
    func testTheArrivalFetchWaitsBeforeItDownloads() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ConstructMessenger/Services/Media/MediaWireCodec.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "private static func prefetch("))
        let body = String(text[start.upperBound...].prefix(3_000))
        let wait = try XCTUnwrap(body.range(of: "try await Task.sleep(for: delay)"), "prefetch does not wait")
        let download = try XCTUnwrap(body.range(of: "downloadAndDecryptMedia("), "prefetch does not download")
        XCTAssertLessThan(wait.lowerBound, download.lowerBound, "prefetch downloads before it waits")
        XCTAssertTrue(body.contains("MediaAutoDownloadPolicy.prefetchDelay()"), "the wait is not drawn from the policy")
    }
}
