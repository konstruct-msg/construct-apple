#if os(iOS)
import SwiftUI

/// Rows that start linking another device. A phone has a camera, so it can scan the other
/// device's QR (the primary path) as well as show its own. macOS: `DeviceLinkActions+macOS.swift`.
struct DeviceLinkActions: View {
    let showOwnQR: () -> Void
    @State private var showingScanner = false

    var body: some View {
        Group {
            // Primary: open the camera to scan the QR shown on the other device.
            ConstructButtonRow(systemImage: "qrcode.viewfinder", title: LocalizedStringKey("link_new_device")) {
                showingScanner = true
            }
            .accessibilityIdentifier(A11y.Devices.linkNew)
            ConstructRowDivider(indent: DevicesSettingsLayout.dividerIndent)
            // Secondary: show this device's QR (camera-broken fallback / other device scans us).
            ConstructButtonRow(systemImage: "qrcode", title: LocalizedStringKey("device_link_show_qr")) {
                showOwnQR()
            }
            .accessibilityIdentifier(A11y.Devices.showQR)
        }
        .sheet(isPresented: $showingScanner) { DeviceLinkScanView() }
    }
}
#endif
