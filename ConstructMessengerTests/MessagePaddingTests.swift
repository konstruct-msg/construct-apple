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
@testable import ConstructMessenger

final class MessagePaddingTests: XCTestCase {

    // Bucket sizes from MessagePaddingConfig
    private let buckets = MessagePaddingConfig.buckets  // [1024, 4096, 16384]
    private let headerLength = 8  // 4 magic + 4 length

    // MARK: - Helpers

    /// Generate random base64 string of `rawByteCount` bytes
    private func makeBase64(bytes count: Int) -> String {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
    }

    // MARK: - Pad → Unpad Roundtrip

    func testRoundtripSmallMessage() {
        let original = makeBase64(bytes: 100)
        let padded = MessagePadding.padCiphertextBase64(original)
        let unpadded = MessagePadding.unpadCiphertextBase64(padded)
        XCTAssertEqual(unpadded, original, "Roundtrip should recover original content")
    }

    func testRoundtripMediumMessage() {
        let original = makeBase64(bytes: 2000)
        let padded = MessagePadding.padCiphertextBase64(original)
        let unpadded = MessagePadding.unpadCiphertextBase64(padded)
        XCTAssertEqual(unpadded, original)
    }

    func testRoundtripLargeMessage() {
        let original = makeBase64(bytes: 10000)
        let padded = MessagePadding.padCiphertextBase64(original)
        let unpadded = MessagePadding.unpadCiphertextBase64(padded)
        XCTAssertEqual(unpadded, original)
    }

    func testRoundtripTinyMessage() {
        let original = makeBase64(bytes: 1)
        let padded = MessagePadding.padCiphertextBase64(original)
        let unpadded = MessagePadding.unpadCiphertextBase64(padded)
        XCTAssertEqual(unpadded, original)
    }

    func testRoundtripMessageExactlyAtBucketBoundary() {
        // A message that exactly fills bucket 0 after adding header
        let targetRawSize = buckets[0] - headerLength
        let original = makeBase64(bytes: targetRawSize)
        let padded = MessagePadding.padCiphertextBase64(original)
        let unpadded = MessagePadding.unpadCiphertextBase64(padded)
        XCTAssertEqual(unpadded, original)
    }

    func testRoundtripMessageOneByteUnderBoundary() {
        let targetRawSize = buckets[0] - headerLength - 1
        let original = makeBase64(bytes: targetRawSize)
        let padded = MessagePadding.padCiphertextBase64(original)
        let unpadded = MessagePadding.unpadCiphertextBase64(padded)
        XCTAssertEqual(unpadded, original)
    }

    // MARK: - Padded Output Size

    func testPaddedOutputFitsFirstBucket() {
        guard MessagePaddingConfig.enabled else { return }
        let original = makeBase64(bytes: 100)
        let padded = MessagePadding.padCiphertextBase64(original)
        let paddedBytes = Data(base64Encoded: padded)!
        XCTAssertEqual(paddedBytes.count, buckets[0],
            "Small message should be padded to first bucket (\(buckets[0]) bytes)")
    }

    func testPaddedOutputFitsSecondBucket() {
        guard MessagePaddingConfig.enabled else { return }
        let original = makeBase64(bytes: buckets[0] - headerLength + 1)  // just over first bucket
        let padded = MessagePadding.padCiphertextBase64(original)
        let paddedBytes = Data(base64Encoded: padded)!
        XCTAssertEqual(paddedBytes.count, buckets[1],
            "Message exceeding first bucket should be padded to second bucket (\(buckets[1]) bytes)")
    }

    func testPaddedOutputFitsThirdBucket() {
        guard MessagePaddingConfig.enabled else { return }
        let original = makeBase64(bytes: buckets[1] - headerLength + 1)  // just over second bucket
        let padded = MessagePadding.padCiphertextBase64(original)
        let paddedBytes = Data(base64Encoded: padded)!
        XCTAssertEqual(paddedBytes.count, buckets[2],
            "Message exceeding second bucket should be padded to third bucket (\(buckets[2]) bytes)")
    }

    func testPaddedSizeIsAlwaysBucketSize() {
        guard MessagePaddingConfig.enabled else { return }
        let testSizes = [1, 50, 100, 500, 1000, 1016, 1017, 2000, 4080, 4089, 8000]
        for size in testSizes {
            let original = makeBase64(bytes: size)
            let padded = MessagePadding.padCiphertextBase64(original)
            if let paddedBytes = Data(base64Encoded: padded) {
                XCTAssertTrue(
                    buckets.contains(paddedBytes.count),
                    "Padded size \(paddedBytes.count) for input \(size) bytes not in buckets \(buckets)"
                )
            }
        }
    }

    // MARK: - Magic Header Verification

    func testPaddedOutputHasMagicHeader() {
        guard MessagePaddingConfig.enabled else { return }
        let magic: [UInt8] = [0x4B, 0x50, 0x41, 0x44]  // "KPAD"
        let original = makeBase64(bytes: 100)
        let padded = MessagePadding.padCiphertextBase64(original)
        let paddedBytes = [UInt8](Data(base64Encoded: padded)!)
        XCTAssertEqual(Array(paddedBytes.prefix(4)), magic, "Padded blob must start with KPAD magic")
    }

    func testPaddedOutputHasCorrectLengthField() {
        guard MessagePaddingConfig.enabled else { return }
        let rawBytes = Data((0..<100).map { UInt8($0) })
        let original = rawBytes.base64EncodedString()
        let padded = MessagePadding.padCiphertextBase64(original)
        let paddedBytes = [UInt8](Data(base64Encoded: padded)!)

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
        let noPadding = makeBase64(bytes: 50)
        let result = MessagePadding.unpadCiphertextBase64(noPadding)
        XCTAssertEqual(result, noPadding, "Without magic, input should be returned unchanged")
    }

    func testUnpadPassesThroughTooShortData() {
        // Less than 8 bytes — no room for header
        let tiny = Data(repeating: 0x4B, count: 4).base64EncodedString()
        let result = MessagePadding.unpadCiphertextBase64(tiny)
        XCTAssertEqual(result, tiny)
    }

    func testUnpadPassesThroughInvalidBase64() {
        let result = MessagePadding.unpadCiphertextBase64("not!valid!base64!!!")
        XCTAssertEqual(result, "not!valid!base64!!!")
    }

    // MARK: - Determinism: Same Input → Same Output Size

    func testSameInputProducesSamePaddedSize() {
        guard MessagePaddingConfig.enabled else { return }
        let original = makeBase64(bytes: 200)
        let padded1 = MessagePadding.padCiphertextBase64(original)
        let padded2 = MessagePadding.padCiphertextBase64(original)
        // Size must be identical (random padding may differ in content but not size)
        let size1 = Data(base64Encoded: padded1)!.count
        let size2 = Data(base64Encoded: padded2)!.count
        XCTAssertEqual(size1, size2)
    }

    // MARK: - Pad passthrough when disabled

    func testPadPassesThroughWhenDisabled() {
        // MessagePaddingConfig.enabled is a static let, so we test the actual value.
        // This test documents the expected behavior: if disabled, input is unchanged.
        if !MessagePaddingConfig.enabled {
            let original = makeBase64(bytes: 100)
            let padded = MessagePadding.padCiphertextBase64(original)
            XCTAssertEqual(padded, original)
        } else {
            // Padding is enabled — verify it actually changes the input
            let original = makeBase64(bytes: 100)
            let padded = MessagePadding.padCiphertextBase64(original)
            XCTAssertNotEqual(padded, original, "Padding should modify the input when enabled")
        }
    }

    // MARK: - All Bucket Sizes Roundtrip

    func testRoundtripAcrossAllBuckets() {
        for bucket in buckets {
            // Test just below each bucket boundary
            let size = max(1, bucket - headerLength - 1)
            let original = makeBase64(bytes: size)
            let padded = MessagePadding.padCiphertextBase64(original)
            let unpadded = MessagePadding.unpadCiphertextBase64(padded)
            XCTAssertEqual(unpadded, original, "Roundtrip failed for size \(size) (bucket \(bucket))")
        }
    }
}
