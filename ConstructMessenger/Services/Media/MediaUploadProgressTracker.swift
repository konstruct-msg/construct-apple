import SwiftUI

/// Tracks per-message media upload progress so the sender's placeholder bubble can show a
/// real (not indeterminate) send progress. Keyed by the placeholder message id; the same id
/// the `MediaMessageView` placeholder renders under. Cleared when the upload completes or fails.
///
/// Download progress is handled locally inside `MediaMessageView` (it owns the download task);
/// upload progress originates deep in the send pipeline (`MediaServiceClient` → `MediaManager`
/// → `ChatSendCoordinator`), so it needs this shared seam to reach the view.
@MainActor
@Observable
final class MediaUploadProgressTracker {
    static let shared = MediaUploadProgressTracker()

    private var progress: [String: Double] = [:]

    private init() {}

    /// Overall album upload fraction (0.0…1.0) for a placeholder message, or nil if not uploading.
    func value(for id: String) -> Double? { progress[id] }

    func set(_ value: Double, for id: String) {
        progress[id] = min(max(value, 0), 1)
    }

    func clear(_ id: String) {
        progress[id] = nil
    }
}
