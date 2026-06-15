import Foundation

enum CallsFeature {
    /// Audio calls — fully implemented.
    static var isEnabled: Bool {
        !PreviewDetector.isRunningInPreview
    }

    /// Video calls — wiring is in place across the call-entrypoint UI and
    /// `startOutgoingCall(hasVideo:)`, but the media layer (camera capture,
    /// remote-video rendering, in-call controls for flip-camera / toggle-video)
    /// is not yet implemented. Flip to `true` when the media work lands; no
    /// UI restructuring is needed.
    static var isVideoEnabled: Bool { false }
}
