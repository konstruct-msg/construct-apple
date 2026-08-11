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

    // MARK: - The default must not cost anything on cellular

    /// The whole argument for turning this on by default: on a metered connection it behaves
    /// exactly as the app did before, so nobody's bill changes. If this ever returns true, the
    /// default has quietly become a bandwidth decision made on the user's behalf.
    func testTheDefaultFetchesNothingOnCellular() {
        XCTAssertFalse(shouldFetch(.unmetered, size: photo, expensive: true))
    }

    /// Low Data Mode is an explicit instruction to hold back on speculative transfers, and it can
    /// be on over Wi-Fi. Reading only `isExpensive` would ignore it.
    func testLowDataModeIsRespectedEvenOnWiFi() {
        XCTAssertFalse(shouldFetch(.unmetered, size: photo, expensive: false, constrained: true))
    }

    func testTheDefaultFetchesAPhotoOnWiFi() {
        XCTAssertTrue(shouldFetch(.unmetered, size: photo))
    }

    /// A photo is bounded at 4 MB by MediaOptimizer; a transcoded clip is not. Pulling 80 MB
    /// because a message arrived is not what leaving the default on means.
    func testTheDefaultDoesNotPullALargeVideoEvenOnWiFi() {
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

    /// A fresh install has nothing stored. It must land on `.unmetered`, not on `.never` via a
    /// zero-valued raw — which is exactly what `rawValue: 0` would give if this fell back to
    /// `MediaAutoDownloadSetting(rawValue:) ?? .init(rawValue: 0)`.
    func testAnUnsetPreferenceResolvesToTheDefaultNotToNever() throws {
        let suite = "autodownload-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        XCTAssertEqual(MediaAutoDownloadPolicy.current(defaults: defaults), .unmetered)
        XCTAssertEqual(MediaAutoDownloadSetting.default, .unmetered)
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
        XCTAssertEqual(MediaAutoDownloadPolicy.current(defaults: defaults), .unmetered)
    }
}
