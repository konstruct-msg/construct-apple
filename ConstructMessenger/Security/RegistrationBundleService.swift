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
            let identityData = Data(fields.identityPublic)
            let preview = identityData.prefix(16).map { String(format: "%02x", $0) }.joined()
            Log.info("Generated registration bundle from Rust core:", category: "CryptoManager")
            Log.info("   MY identityPublic: \(preview)… (len: \(identityData.count))", category: "CryptoManager")
            Log.info("   suiteId: \(fields.suiteId)", category: "CryptoManager")
            return RegistrationBundle(
                identityPublic: identityData,
                signedPrekeyPublic: Data(fields.signedPrekeyPublic),
                signature: Data(fields.signature),
                verifyingKey: Data(fields.verifyingKey),
                suiteId: fields.suiteId
            )
        } catch {
            Log.error("Failed to generate registration bundle: \(error)", category: "CryptoManager")
            return nil
        }
    }
}
