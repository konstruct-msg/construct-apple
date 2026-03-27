//
//  RegistrationBundleService.swift
//  Construct Messenger
//

import Foundation
import os.log

final class RegistrationBundleService {
    func generateRegistrationBundle(core: OrchestratorCore?) -> RegistrationBundle? {
        guard let core = core else { return nil }
        do {
            let fields = try core.getRegistrationBundleFields()
            Log.info("📦 Generated registration bundle from Rust core:", category: "CryptoManager")
            if let identityData = Data(base64Encoded: fields.identityPublic) {
                let preview = identityData.prefix(16).map { String(format: "%02x", $0) }.joined()
                Log.info("   🔑 MY identityPublic: \(preview)… (len: \(fields.identityPublic.count))", category: "CryptoManager")
            }
            Log.info("   suiteId: \(fields.suiteId)", category: "CryptoManager")
            return RegistrationBundle(
                identityPublic: fields.identityPublic,
                signedPrekeyPublic: fields.signedPrekeyPublic,
                signature: fields.signature,
                verifyingKey: fields.verifyingKey,
                suiteId: fields.suiteId
            )
        } catch {
            Log.error("❌ Failed to generate registration bundle: \(error)", category: "CryptoManager")
            return nil
        }
    }
}
