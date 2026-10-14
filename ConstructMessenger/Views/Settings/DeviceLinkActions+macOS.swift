#if os(macOS)
import SwiftUI

/// macOS has no camera — the only path is showing this device's QR.
/// iOS: `DeviceLinkActions+iOS.swift`.
struct DeviceLinkActions: View {
    let showOwnQR: () -> Void

    var body: some View {
        ConstructButtonRow(systemImage: "qrcode", title: LocalizedStringKey("link_new_device")) {
            showOwnQR()
        }
    }
}
#endif
