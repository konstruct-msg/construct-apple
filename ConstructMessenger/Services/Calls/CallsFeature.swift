import Foundation

enum CallsFeature {
    /// Audio calls — implemented for iOS; Desktop entry points stay disabled while the
    /// protocol is being stabilized.
    static var isEnabled: Bool {
        #if os(macOS)
        false
        #else
        !PreviewDetector.isRunningInPreview
        #endif
    }

    /// Video calls — stage 1 of TODO 105 (`client/specs/VIDEO_CALLS_DESIGN.md`): camera, rendering
    /// and `MediaUpdate`, with a placeholder screen. Off unless switched on in the developer section
    /// of Diagnostics, and absent from a release build.
    ///
    /// A switch rather than `DEBUG` alone: TestFlight builds are the Beta configuration, which
    /// defines `DEBUG`, and every call made with this on puts a video section into its offer. Until
    /// that has been seen to leave an audio call to an Android or older iOS build untouched on real
    /// devices, nobody gets it without turning it on.
    static let videoSwitchKey = "ff.callsVideo"

    static var isVideoEnabled: Bool {
        #if DEBUG && os(iOS)
        isEnabled && UserDefaults.standard.bool(forKey: videoSwitchKey)
        #else
        false
        #endif
    }
}
