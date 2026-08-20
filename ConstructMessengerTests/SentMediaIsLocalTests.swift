//
//  SentMediaIsLocalTests.swift
//  ConstructMessengerTests
//
//  The incident: tapping play on your OWN voice note fetched it from the server, seconds after the
//  microphone produced it. `uploadAudio` was the only upload path that never seeded the local
//  plaintext cache — image, original-image and video each called `cacheSentMedia` by hand, and
//  audio, file and avatar did not. Nothing enforced it; it was a thing six call sites were each
//  expected to remember.
//
//  The fix is placement, not logic: the seeding moved into `uploadWithRetry`, which every upload
//  passes through, and the per-path calls were deleted. These tests cover the mechanism that fix
//  relies on — that a seeded blob is served locally.
//
//  NOT COVERED HERE, stated rather than implied: that the audio path actually reaches
//  `uploadWithRetry`. No test in this target can upload. The device answers it — record a voice
//  note, send it, tap play, and the log must read
//
//      Media cache hit (memory) for: <mediaId>
//
//  with no `downloadWithRetry` and no transport rpc for that id.
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class SentMediaIsLocalTests: XCTestCase {

    /// A four-second voice note at 64 kbps mono is ~32 KB — comfortably under the memory-cache
    /// item ceiling, which is the case that must be a RAM hit rather than a disk read.
    private let voiceNote = Data(repeating: 0x41, count: 32_000)

    /// The url and key here are deliberately unusable. If the cache is consulted the call returns
    /// without touching either; if it is not, the test fails instead of quietly passing on a
    /// network round trip that happens to work.
    private let unreachable = "https://media.invalid.example/never"

    func testOwnVoiceNoteIsServedLocallyAfterSending() async throws {
        let mediaId = "voice-\(UUID().uuidString)"
        MediaManager.shared.cacheSentMedia(voiceNote, mediaId: mediaId)

        let played = try await MediaManager.shared.downloadAndDecryptMedia(
            mediaId: mediaId, mediaUrl: unreachable, mediaKey: Data()
        )

        XCTAssertEqual(played, voiceNote, "playback must not depend on the network for our own upload")
    }

    /// The same guarantee is what makes the gallery's own-send path a local hit rather than a
    /// re-download (see MediaImageCacheCompartmentTests for the resolution half of that fix).
    func testASentImageIsServedLocally() async throws {
        let mediaId = "image-\(UUID().uuidString)"
        let image = Data(repeating: 0x7F, count: 200_000)
        MediaManager.shared.cacheSentMedia(image, mediaId: mediaId)

        let fetched = try await MediaManager.shared.downloadAndDecryptMedia(
            mediaId: mediaId, mediaUrl: unreachable, mediaKey: Data()
        )

        XCTAssertEqual(fetched, image)
    }

    /// A blob too large for RAM must still come back — from disk. `cacheSentMedia` writes both,
    /// and only the memory half is size-gated; if the disk write were dropped as "redundant", a
    /// video would silently start re-downloading for the sender.
    func testAnOversizedBlobStillComesBackFromDisk() async throws {
        let mediaId = "video-\(UUID().uuidString)"
        let big = Data(repeating: 0x11, count: MediaManager.maxMemoryItemBytes + 1)
        XCTAssertFalse(
            MediaManager.shouldCacheInMemory(byteCount: big.count),
            "precondition: this size must be rejected by the memory cache, or the test proves nothing"
        )
        MediaManager.shared.cacheSentMedia(big, mediaId: mediaId)

        let fetched = try await MediaManager.shared.downloadAndDecryptMedia(
            mediaId: mediaId, mediaUrl: unreachable, mediaKey: Data()
        )

        XCTAssertEqual(fetched.count, big.count)
    }

    /// Nothing was seeded for this id, so the cache must not invent an answer — otherwise the
    /// tests above would pass against a stub that returns anything.
    func testAnUnknownIdIsNotServedFromCache() async {
        do {
            _ = try await MediaManager.shared.downloadAndDecryptMedia(
                mediaId: "never-uploaded-\(UUID().uuidString)",
                mediaUrl: unreachable,
                mediaKey: Data()
            )
            XCTFail("an id that was never cached must not resolve locally")
        } catch {
            // Expected: it goes looking, and there is nothing to find.
        }
    }
}
