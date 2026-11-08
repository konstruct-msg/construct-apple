//
//  ARefusedRecoveryLeavesTheKeysTests.swift
//  ConstructMessengerTests
//
//  todo/269: a recovery saved its new keys before the server answered. A refused one left a key
//  record without a device id — read at the next launch as keys lost — and overwrote the record a
//  device with unreadable keys recovers from. The keys now become the device's only once the
//  server has taken them.
//

import XCTest
import GRPCCore
import CryptoKit
@testable import Construct_Messenger

@MainActor
final class ARefusedRecoveryLeavesTheKeysTests: XCTestCase {
    private var keptRecord: Data?
    private var keptDeviceId: String?

    override func setUp() async throws {
        keptRecord = KeychainManager.shared.loadPrivateKeysData()
        keptDeviceId = KeychainManager.shared.loadDeviceID()
    }

    override func tearDown() async throws {
        if let keptRecord {
            KeychainManager.shared.savePrivateKeys(keptRecord)
        } else {
            KeychainManager.shared.deletePrivateKeys()
        }
        if let keptDeviceId {
            KeychainManager.shared.saveDeviceID(keptDeviceId)
        } else {
            KeychainManager.shared.deleteDeviceKeys()
        }
    }

    /// A device with keys of its own: a record and the id it derives.
    private func deviceWithKeys() throws -> CryptoManager.UnsavedDeviceKeys {
        let keys = try CryptoManager.shared.generateUnsavedDeviceKeys()
        XCTAssertTrue(CryptoManager.shared.adopt(keys))
        KeychainManager.shared.saveDeviceID(keys.deviceId)
        return keys
    }

    private func recovery(refusingWith code: RPCError.Code) throws -> (AccountRecoveryViewModel, () -> String?) {
        let vm = AccountRecoveryViewModel()
        vm.enteredWords = try generateMnemonic(wordCount: 12).split(separator: " ").map(String.init)
        vm.recoverIdentifier = "someone"
        var offered: String?
        vm.recoverRequest = { _, _, deviceId, _, _ in
            offered = deviceId
            throw RPCError(code: code, message: "refused in a test")
        }
        return (vm, { offered })
    }

    func testARefusedRecoveryLeavesTheDevicesKeysAsTheyWere() async throws {
        let own = try deviceWithKeys()
        let recordBefore = KeychainManager.shared.loadPrivateKeysData()

        for code in [RPCError.Code.unavailable, .permissionDenied] {
            let (vm, offered) = try recovery(refusingWith: code)
            await vm.submitRecover()

            guard case .failed = vm.recoverStep else {
                return XCTFail("\(code): the recovery reads as failed, not \(vm.recoverStep)")
            }
            let offeredId = try XCTUnwrap(offered(), "\(code): the request was made")
            XCTAssertNotEqual(offeredId, own.deviceId, "\(code): it offered new keys")
            XCTAssertEqual(
                KeychainManager.shared.loadPrivateKeysData(), recordBefore,
                "\(code): the key record is the device's own, not the keys the server refused"
            )
            XCTAssertEqual(KeychainManager.shared.loadDeviceID(), own.deviceId, "\(code)")
        }
    }

    /// On a device with no keys yet, a refused recovery leaves none: the next launch is a first
    /// one, not "keys not found".
    func testARefusedRecoveryOnANewDeviceLeavesNoHalfIdentity() async throws {
        KeychainManager.shared.deletePrivateKeys()
        KeychainManager.shared.deleteDeviceKeys()

        let (vm, offered) = try recovery(refusingWith: .unavailable)
        await vm.submitRecover()

        XCTAssertNotNil(offered())
        XCTAssertEqual(
            DeviceKeyAvailability.resolve(
                deviceId: KeychainManager.shared.readDeviceID(),
                keyRecord: KeychainManager.shared.readPrivateKeys()
            ),
            .absent
        )
    }

    /// The keys the server took are the ones kept.
    func testAdoptedKeysAreTheRecord() throws {
        let keys = try CryptoManager.shared.generateUnsavedDeviceKeys()
        let before = KeychainManager.shared.loadPrivateKeysData()
        XCTAssertEqual(KeychainManager.shared.loadPrivateKeysData(), before, "unsaved until adopted")

        XCTAssertTrue(CryptoManager.shared.adopt(keys))
        let record = try XCTUnwrap(KeychainManager.shared.loadPrivateKeysData())
        XCTAssertNotEqual(record, before)
        // The record signs as the verifying key the server was offered.
        let message = Data("todo/269".utf8)
        let signature = try signBundleDataWithKeys(keys: record, bundleDataJson: message)
        let verifying = try Curve25519.Signing.PublicKey(rawRepresentation: keys.bundle.verifyingKey)
        XCTAssertTrue(verifying.isValidSignature(signature, for: message))
    }
}
