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

    /// Video calls (TODO 105, `client/specs/VIDEO_CALLS_DESIGN.md`). On by default in Debug and
    /// TestFlight builds since 2026-10-06 (owner), after an iOS↔iOS video call worked on two
    /// devices; the switch in the developer section of Diagnostics still turns them off. Absent
    /// from a release build.
    ///
    /// Release stays off on purpose: every call made with this on puts a video section into its
    /// offer, and that has not yet been seen to leave an audio call to an Android build untouched
    /// on real devices.
    static let videoSwitchKey = "ff.callsVideo"
    static let videoDefault = true

    static var isVideoEnabled: Bool {
        #if DEBUG && os(iOS)
        isEnabled && (UserDefaults.standard.object(forKey: videoSwitchKey) as? Bool ?? videoDefault)
        #else
        false
        #endif
    }
}
