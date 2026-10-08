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

    /// Video calls (TODO 105, `client/specs/VIDEO_CALLS_DESIGN.md`). On in every iOS build since
    /// 2026-10-08 (owner) — Debug and TestFlight had them since 2026-10-06, after an iOS↔iOS
    /// video call worked on two devices.
    ///
    /// The switch in the developer section of Diagnostics exists in Debug builds only, so it is
    /// read only there; a release build has nothing that could turn video off.
    ///
    /// Open when this was enabled: with video on, every call — audio ones too — puts a video
    /// section into its offer, and an audio call to an Android build has not yet been seen to
    /// stay untouched by it on real devices. The owner checks that before the release step.
    static let videoSwitchKey = "ff.callsVideo"
    static let videoDefault = true

    static var isVideoEnabled: Bool {
        #if os(iOS)
        #if DEBUG
        isEnabled && (UserDefaults.standard.object(forKey: videoSwitchKey) as? Bool ?? videoDefault)
        #else
        isEnabled
        #endif
        #else
        false
        #endif
    }
}
