//
//  MessagePaddingTests.swift
//  ConstructMessengerTests
//
//  Tests for MessagePadding — ciphertext bucket-padding for traffic analysis resistance.
//
//  Wire format of padded blob:
//    [4 bytes] magic = "KPAD" (0x4B 0x50 0x41 0x44)
//    [4 bytes] original_length (big-endian u32)
//    [N bytes] original ciphertext
//    [P bytes] random padding to reach bucket size
//

import XCTest
@testable import Construct_Messenger

final class MessagePaddingTests: XCTestCase {

    // Bucket sizes from MessagePaddingConfig
    private let buckets = MessagePaddingConfig.buckets  // [1024, 4096, 16384]
    private let headerLength = 8  // 4 magic + 4 length

    // MARK: - Helpers

    private func makeData(bytes count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    // MARK: - Pad → Unpad Roundtrip

    func testRoundtripSmallMessage() {
        let original = makeData(bytes: 100)
        let padded = MessagePadding.padCiphertext(original)
        let unpadded = MessagePadding.unpadCiphertext(padded)
        XCTAssertEqual(unpadded, original, "Roundtrip should recover original content")
    }

    func testRoundtripMediumMessage() {
        let original = makeData(bytes: 2000)
        let padded = MessagePadding.padCiphertext(original)
        let unpadded = MessagePadding.unpadCiphertext(padded)
        XCTAssertEqual(unpadded, original)
    }

    func testRoundtripLargeMessage() {
        let original = makeData(bytes: 10000)
        let padded = MessagePadding.padCiphertext(original)
        let unpadded = MessagePadding.unpadCiphertext(padded)
        XCTAssertEqual(unpadded, original)
    }

    func testRoundtripTinyMessage() {
        let original = makeData(bytes: 1)
        let padded = MessagePadding.padCiphertext(original)
        let unpadded = MessagePadding.unpadCiphertext(padded)
        XCTAssertEqual(unpadded, original)
    }

    func testRoundtripMessageExactlyAtBucketBoundary() {
        let targetRawSize = buckets[0] - headerLength
        let original = makeData(bytes: targetRawSize)
        let padded = MessagePadding.padCiphertext(original)
        let unpadded = MessagePadding.unpadCiphertext(padded)
        XCTAssertEqual(unpadded, original)
    }

    func testRoundtripMessageOneByteUnderBoundary() {
        let targetRawSize = buckets[0] - headerLength - 1
        let original = makeData(bytes: targetRawSize)
        let padded = MessagePadding.padCiphertext(original)
        let unpadded = MessagePadding.unpadCiphertext(padded)
        XCTAssertEqual(unpadded, original)
    }

    // MARK: - Padded Output Size

    func testPaddedOutputFitsFirstBucket() {
        guard MessagePaddingConfig.enabled else { return }
        let padded = MessagePadding.padCiphertext(makeData(bytes: 100))
        XCTAssertEqual(padded.count, buckets[0],
            "Small message should be padded to first bucket (\(buckets[0]) bytes)")
    }

    func testPaddedOutputFitsSecondBucket() {
        guard MessagePaddingConfig.enabled else { return }
        let padded = MessagePadding.padCiphertext(makeData(bytes: buckets[0] - headerLength + 1))
        XCTAssertEqual(padded.count, buckets[1],
            "Message exceeding first bucket should be padded to second bucket (\(buckets[1]) bytes)")
    }

    func testPaddedOutputFitsThirdBucket() {
        guard MessagePaddingConfig.enabled else { return }
        let padded = MessagePadding.padCiphertext(makeData(bytes: buckets[1] - headerLength + 1))
        XCTAssertEqual(padded.count, buckets[2],
            "Message exceeding second bucket should be padded to third bucket (\(buckets[2]) bytes)")
    }

    func testPaddedSizeIsAlwaysBucketSize() {
        guard MessagePaddingConfig.enabled else { return }
        let testSizes = [1, 50, 100, 500, 1000, 1016, 1017, 2000, 4080, 4089, 8000]
        for size in testSizes {
            let padded = MessagePadding.padCiphertext(makeData(bytes: size))
            XCTAssertTrue(
                buckets.contains(padded.count),
                "Padded size \(padded.count) for input \(size) bytes not in buckets \(buckets)"
            )
        }
    }

    // MARK: - Magic Header Verification

    func testPaddedOutputHasMagicHeader() {
        guard MessagePaddingConfig.enabled else { return }
        let magic: [UInt8] = [0x4B, 0x50, 0x41, 0x44]  // "KPAD"
        let padded = [UInt8](MessagePadding.padCiphertext(makeData(bytes: 100)))
        XCTAssertEqual(Array(padded.prefix(4)), magic, "Padded blob must start with KPAD magic")
    }

    func testPaddedOutputHasCorrectLengthField() {
        guard MessagePaddingConfig.enabled else { return }
        let rawBytes = Data((0..<100).map { UInt8($0) })
        let paddedBytes = [UInt8](MessagePadding.padCiphertext(rawBytes))

        // Bytes 4–7 are big-endian u32 of original length
        let storedLength = (UInt32(paddedBytes[4]) << 24)
            | (UInt32(paddedBytes[5]) << 16)
            | (UInt32(paddedBytes[6]) << 8)
            | UInt32(paddedBytes[7])
        XCTAssertEqual(storedLength, UInt32(rawBytes.count), "Length field must store original byte count")
    }

    // MARK: - Unpad Error Handling

    func testUnpadPassesThroughDataWithoutMagic() {
        // Data without KPAD magic should be returned unchanged
        let noPadding = makeData(bytes: 50)
        let result = MessagePadding.unpadCiphertext(noPadding)
        XCTAssertEqual(result, noPadding, "Without magic, input should be returned unchanged")
    }

    func testUnpadPassesThroughTooShortData() {
        let tiny = Data(repeating: 0x4B, count: 4)
        let result = MessagePadding.unpadCiphertext(tiny)
        XCTAssertEqual(result, tiny)
    }

    // MARK: - Determinism: Same Input → Same Output Size

    func testSameInputProducesSamePaddedSize() {
        guard MessagePaddingConfig.enabled else { return }
        let original = makeData(bytes: 200)
        let size1 = MessagePadding.padCiphertext(original).count
        let size2 = MessagePadding.padCiphertext(original).count
        XCTAssertEqual(size1, size2)
    }

    // MARK: - Pad passthrough when disabled

    func testPadPassesThroughWhenDisabled() {
        if !MessagePaddingConfig.enabled {
            let original = makeData(bytes: 100)
            XCTAssertEqual(MessagePadding.padCiphertext(original), original)
        } else {
            let original = makeData(bytes: 100)
            XCTAssertNotEqual(MessagePadding.padCiphertext(original), original,
                "Padding should modify the input when enabled")
        }
    }

    // MARK: - All Bucket Sizes Roundtrip

    func testRoundtripAcrossAllBuckets() {
        for bucket in buckets {
            let size = max(1, bucket - headerLength - 1)
            let original = makeData(bytes: size)
            let padded = MessagePadding.padCiphertext(original)
            let unpadded = MessagePadding.unpadCiphertext(padded)
            XCTAssertEqual(unpadded, original, "Roundtrip failed for size \(size) (bucket \(bucket))")
        }
    }
}
