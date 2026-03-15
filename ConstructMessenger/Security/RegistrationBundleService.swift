//
//  RegistrationBundleService.swift
//  Construct Messenger
//
//  Extracted from CryptoManager (refactor)
//

import Foundation
import os.log

final class RegistrationBundleService {
    func generateRegistrationBundle(core: OrchestratorCore?) -> RegistrationBundle? {
        guard let core = core else { return nil }

        do {
            let jsonString = try core.exportRegistrationBundleJson()
            guard let jsonData = jsonString.data(using: .utf8) else {
                return nil
            }

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let bundle = try decoder.decode(RegistrationBundle.self, from: jsonData)
            
            // Log bundle generation details (ALWAYS for debugging)
            Log.info("📦 Generated registration bundle from Rust core:", category: "CryptoManager")
            if let identityData = Data(base64Encoded: bundle.identityPublic) {
                let preview = identityData.prefix(16).map { String(format: "%02x", $0) }.joined()
                Log.info("   🔑 MY identityPublic: \(preview)... (len: \(bundle.identityPublic.count))", category: "CryptoManager")
            }
            if let prekeyData = Data(base64Encoded: bundle.signedPrekeyPublic) {
                let preview = prekeyData.prefix(16).map { String(format: "%02x", $0) }.joined()
                Log.info("   🔑 MY signedPrekeyPublic: \(preview)... (len: \(bundle.signedPrekeyPublic.count))", category: "CryptoManager")
            }
            if let verifyingData = Data(base64Encoded: bundle.verifyingKey) {
                let preview = verifyingData.prefix(16).map { String(format: "%02x", $0) }.joined()
                Log.info("   🔑 MY verifyingKey: \(preview)... (len: \(bundle.verifyingKey.count))", category: "CryptoManager")
            }
            Log.info("   suiteId: \(bundle.suiteId)", category: "CryptoManager")
            
            return bundle
        } catch {
            Log.error("❌ Failed to generate registration bundle: \(error)", category: "CryptoManager")
            return nil
        }
    }
}
