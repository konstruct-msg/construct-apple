//
//  BundleSignatureService.swift
//  Construct Messenger
//
//  Extracted from CryptoManager (refactor)
//

import Foundation

final class BundleSignatureService {
    func signBundleData(_ bundleDataJSON: Data, core: ClassicCryptoCore?) throws -> String {
        guard let core = core else {
            throw CryptoManagerError.coreNotInitialized
        }

        do {
            let bundleDataBytes = [UInt8](bundleDataJSON)
            return try core.signBundleData(bundleDataJson: bundleDataBytes)
        } catch {
            throw CryptoManagerError.invalidKeyData
        }
    }
}
