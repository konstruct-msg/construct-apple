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

    /// Video calls — wiring is in place across the call-entrypoint UI and
    /// `startOutgoingCall(hasVideo:)`, but the media layer (camera capture,
    /// remote-video rendering, in-call controls for flip-camera / toggle-video)
    /// is not yet implemented. Flip to `true` when the media work lands; no
    /// UI restructuring is needed.
    static var isVideoEnabled: Bool { false }
}
