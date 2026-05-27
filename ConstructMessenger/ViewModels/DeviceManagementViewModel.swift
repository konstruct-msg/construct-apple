//
//  DeviceManagementViewModel.swift
//  Construct Messenger
//
//  Manages the list of linked devices and supports remote revocation.
//

import Foundation
import Observation

@MainActor
@Observable
final class DeviceManagementViewModel {

    var devices: [AuthServiceClient.LinkedDevice] = []
    var isLoading: Bool = false
    var errorMessage: String? = nil
    var revocationInProgress: Set<String> = []

    // MARK: - Load

    func loadDevices() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            devices = try await AuthServiceClient.shared.listDevices()
            Log.info("Loaded \(devices.count) linked device(s)", category: "DeviceManagement")
        } catch {
            errorMessage = error.localizedDescription
            Log.error("listDevices failed: \(error)", category: "DeviceManagement")
        }
    }

    // MARK: - Revoke

    func revokeDevice(id: String) async {
        guard !isCurrent(deviceId: id) else {
            errorMessage = "Cannot remove the current device from here. Use Sign Out instead."
            return
        }
        revocationInProgress.insert(id)
        defer { revocationInProgress.remove(id) }

        do {
            try await AuthServiceClient.shared.revokeDevice(deviceId: id)
            devices.removeAll { $0.id == id }
            Log.info("Revoked device \(id.prefix(8))…", category: "DeviceManagement")
        } catch {
            errorMessage = error.localizedDescription
            Log.error("revokeDevice failed: \(error)", category: "DeviceManagement")
        }
    }

    // MARK: - Helpers

    func isRevoking(_ deviceId: String) -> Bool {
        revocationInProgress.contains(deviceId)
    }

    private func isCurrent(deviceId: String) -> Bool {
        devices.first(where: { $0.id == deviceId })?.isCurrent == true
    }
}
