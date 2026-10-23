//
//  DeviceCertificateIssuer.swift
//  Construct Messenger
//
//  The old device's half of a link: vouch for the new device once its keys are in the directory.
//  `construct-docs/decisions/devices-of-an-account-sign-each-other.md`.
//
//  The certificate cannot be issued at the moment of approval. In both flows the new device's
//  hybrid key and its binding reach the directory only after the link completes — it publishes
//  them with its first prekey upload — so this waits for them, then asks the core, then
//  publishes. The core signs only keys the QR named; a directory that serves other keys gets
//  `EvidenceMismatch`, which is logged as what it is and never retried.
//
//  Pending work lives in memory: a link is something the owner watches happen, and an app
//  killed in those minutes leaves the device unvouched — peers then see the alarm, the safe side.
//

import Foundation

@MainActor
final class DeviceCertificateIssuer {
    static let shared = DeviceCertificateIssuer()

    /// What the link QR showed about the new device.
    enum Evidence: Equatable {
        /// Flow B: the new device's QR carried `fp`.
        case qrFingerprint(Data)
        /// Flow A: our QR carried `secret`; the new device answered with `proof`.
        case qrSecret(secret: Data, proof: Data)

        var core: DeviceLinkEvidence {
            switch self {
            case .qrFingerprint(let fp): return .qrFingerprint(fingerprint: fp)
            case .qrSecret(let secret, let proof): return .qrSecret(secret: secret, proof: proof)
            }
        }
    }

    private var tasks: [String: Task<Void, Never>] = [:]

    /// How long the new device has to publish its keys, and how often the directory is asked.
    private static let keysDeadline: TimeInterval = 15 * 60
    private static let pollInterval: Duration = .seconds(5)

    /// Flow A, after our QR was shown: wait for the device that uses the token, then vouch for it
    /// with the proof it sent under `secret`.
    func awaitLink(token: String, secret: Data) {
        start(key: "token:" + token) { [weak self] in
            let deadline = Date().addingTimeInterval(Self.keysDeadline)
            while Date() < deadline, !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                let result: AuthServiceClient.DeviceLinkResult
                do {
                    result = try await AuthServiceClient.shared.getDeviceLinkResult(linkToken: token)
                } catch {
                    Log.debug("device_cert link result: \(error)", category: "DeviceLink")
                    continue
                }
                switch result {
                case .pending:
                    continue
                case .expired:
                    return
                case .confirmed(let deviceId, let proof):
                    guard !proof.isEmpty else {
                        // A new device older than certificates: nothing proves its keys, so they
                        // are not signed. Its peers see it unvouched.
                        Log.info("device_cert device=\(deviceId.prefix(8))… no proof of keys — not vouched", category: "DeviceLink")
                        return
                    }
                    await self?.vouchLoop(deviceId: deviceId, evidence: .qrSecret(secret: secret, proof: proof), deadline: deadline)
                    return
                }
            }
        }
    }

    /// Flow B, after approving a join request whose QR carried `fp`: vouch for `deviceId`.
    func vouch(deviceId: String, evidence: Evidence) {
        start(key: "device:" + deviceId) { [weak self] in
            await self?.vouchLoop(
                deviceId: deviceId,
                evidence: evidence,
                deadline: Date().addingTimeInterval(Self.keysDeadline)
            )
        }
    }

    private func start(key: String, _ body: @escaping @MainActor () async -> Void) {
        tasks[key]?.cancel()
        tasks[key] = Task { [weak self] in
            await body()
            self?.tasks[key] = nil
        }
    }

    private func vouchLoop(deviceId: String, evidence: Evidence, deadline: Date) async {
        guard let ownUserId = KeychainManager.shared.loadUserID() else { return }
        while Date() < deadline, !Task.isCancelled {
            let bundles: [DeviceBundleData]
            do {
                bundles = try await KeyServiceClient.shared.getPreKeyBundles(
                    userId: ownUserId,
                    deviceIds: [deviceId],
                    consumeOneTimePrekey: false
                )
            } catch {
                Log.debug("device_cert fetch \(deviceId.prefix(8))…: \(error)", category: "DeviceLink")
                try? await Task.sleep(for: Self.pollInterval)
                continue
            }
            guard let subject = bundles.first(where: { $0.deviceId == deviceId })
                .flatMap(Self.subjectKeys(from:))
            else {
                // Not published yet: the new device uploads its hybrid key after the link.
                try? await Task.sleep(for: Self.pollInterval)
                continue
            }
            let certificate: Data
            do {
                certificate = try CryptoManager.shared.issueDeviceCertificate(subject: subject, evidence: evidence.core)
            } catch DeviceCertError.EvidenceMismatch {
                // The directory serves keys other than the ones the QR showed: this is the
                // substitution the certificate exists to catch. Never signed, never retried.
                Log.fault("device_cert device=\(deviceId.prefix(8))… directory keys differ from the link QR — refused", category: "DeviceLink")
                return
            } catch {
                Log.error("device_cert issue \(deviceId.prefix(8))…: \(error)", category: "DeviceLink")
                return
            }
            do {
                try await AuthServiceClient.shared.publishDeviceCertificate(subjectDeviceId: deviceId, certificate: certificate)
                Log.info("device_cert device=\(deviceId.prefix(8))… vouched", category: "DeviceLink")
                return
            } catch {
                Log.debug("device_cert publish \(deviceId.prefix(8))…: \(error)", category: "DeviceLink")
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
        Log.info("device_cert device=\(deviceId.prefix(8))… keys not published in time — not vouched", category: "DeviceLink")
    }

    /// The keys a certificate covers, as the directory serves them; nil until the device has
    /// published its hybrid key and the binding to its Ed25519 key.
    nonisolated static func subjectKeys(from entry: DeviceBundleData) -> DeviceCertKeys? {
        let b = entry.bundle
        guard let binding = b.hybridIdentitySignature, !binding.isEmpty,
              !entry.hybridIdentityKey.isEmpty
        else { return nil }
        return DeviceCertKeys(
            identityPublic: b.identityPublic,
            verifyingKey: b.verifyingKey,
            hybridPublic: entry.hybridIdentityKey,
            hybridBinding: binding
        )
    }
}
