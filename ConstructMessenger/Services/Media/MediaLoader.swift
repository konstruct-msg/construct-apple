import Foundation

/// The download-and-decrypt half of showing one media item, shared by the views that used to each
/// carry their own copy: the single-image bubble, the album tile, the gallery's image page and
/// its video page.
///
/// What is shared: the cache lookup, `downloadAndDecryptMedia` with byte progress, the state the
/// view paints (idle / loading / loaded / failed), the store into the caller's cache and the
/// failure log. What stays at the call site, passed in as closures: *which* cache is consulted
/// and written (display, original, video file), how the bytes become a value (a downsampled
/// image, a full decode, a temp `.mp4`), and everything the view does with the result (posters,
/// blurhash, thumbnails). One loader belongs to one media item.
@MainActor
@Observable
final class MediaLoader<Output> {

    /// The fields of a media item's descriptor a download needs.
    struct Descriptor {
        let mediaId: String
        let mediaUrl: String
        let mediaKey: Data
        /// Encrypted size from the descriptor; 0 when absent, which leaves progress unreported.
        let size: Int

        /// `nil` while the descriptor is not readable (yet) — that is not a failure, the caller
        /// decides what it means.
        init?(item: [String: Any]) {
            guard let mediaId = item["mediaId"] as? String,
                  let mediaUrl = item["mediaUrl"] as? String,
                  let keyString = item["mediaKey"] as? String,
                  let mediaKey = Data(base64Encoded: keyString)
            else { return nil }
            self.mediaId = mediaId
            self.mediaUrl = mediaUrl
            self.mediaKey = mediaKey
            self.size = (item["size"] as? Int) ?? 0
        }
    }

    enum Failure {
        /// The server no longer has it; retrying the same descriptor cannot help.
        case unavailable(Error)
        /// Transport trouble that may recover.
        case retryable(Error)
        /// The bytes arrived and decrypted but are not a usable value.
        case undecodable

        var error: Error? {
            switch self {
            case .unavailable(let e), .retryable(let e): return e
            case .undecodable: return nil
            }
        }

        var isPermanentlyUnavailable: Bool {
            if case .unavailable = self { return true }
            return false
        }
    }

    enum State {
        case idle
        case loading(progress: Double)
        case loaded(Output)
        case failed(Failure)
    }

    typealias Fetch = (_ mediaId: String, _ mediaUrl: String, _ mediaKey: Data,
                       _ onProgress: (@Sendable (Int64) -> Void)?) async throws -> Data

    /// Progress shown while bytes arrive never reaches 1 — the decode still has to run.
    struct Pacing {
        /// Ceiling for the byte-driven fraction.
        var cap: Double = 0.9
        /// Value once the bytes are in and decoding starts; `nil` leaves progress where it is.
        var afterDownload: Double? = 0.95
    }

    private(set) var state: State = .idle
    /// True once a byte has arrived for the current attempt — the view shows a percentage only
    /// then, a spinner before.
    private(set) var hasReceivedBytes = false

    private let fetch: Fetch
    private let pacing: Pacing
    private let logCategory: String
    private let logLabel: String

    init(
        pacing: Pacing = Pacing(),
        logCategory: String = "MediaLoader",
        logLabel: String = "Media",
        fetch: @escaping Fetch = { id, url, key, progress in
            try await MediaManager.shared.downloadAndDecryptMedia(
                mediaId: id, mediaUrl: url, mediaKey: key, onProgress: progress)
        }
    ) {
        self.pacing = pacing
        self.logCategory = logCategory
        self.logLabel = logLabel
        self.fetch = fetch
    }

    var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    var progress: Double {
        switch state {
        case .loading(let p): return p
        case .loaded: return 1
        case .idle, .failed: return 0
        }
    }

    var failure: Failure? {
        if case .failed(let f) = state { return f }
        return nil
    }

    var value: Output? {
        if case .loaded(let v) = state { return v }
        return nil
    }

    /// Resolve the item: `cached` first (no fetch on a hit), otherwise download, `decode`, `store`.
    /// Returns the value, or `nil` with `state` saying why. Callable again from `.failed` — that is
    /// the retry. A call while a load is in flight is ignored.
    func load(
        _ descriptor: Descriptor,
        cached: () -> Output?,
        decode: (Data) async throws -> Output?,
        store: (Output) -> Void
    ) async -> Output? {
        guard !isLoading else { return nil }
        hasReceivedBytes = false
        if let hit = cached() {
            state = .loaded(hit)
            return hit
        }
        state = .loading(progress: 0)

        let total = Double(descriptor.size)
        let cap = pacing.cap
        let onProgress: @Sendable (Int64) -> Void = { [weak self] received in
            Task { @MainActor in
                guard let self, self.isLoading, total > 0 else { return }
                self.hasReceivedBytes = true
                self.state = .loading(progress: min(cap, Double(received) / total))
            }
        }

        let short = descriptor.mediaId.prefix(8)
        do {
            let data = try await fetch(descriptor.mediaId, descriptor.mediaUrl, descriptor.mediaKey, onProgress)
            if let after = pacing.afterDownload, isLoading { state = .loading(progress: after) }
            guard let value = try await decode(data) else {
                fail(.undecodable)
                return nil
            }
            store(value)
            hasReceivedBytes = true
            state = .loaded(value)
            return value
        } catch {
            let failure: Failure
            switch MediaLoadFailurePolicy.disposition(for: error) {
            case .permanentlyUnavailable:
                Log.debug("\(logLabel) unavailable for \(short)…: \(error)", category: logCategory)
                failure = .unavailable(error)
            case .retryable:
                Log.error("\(logLabel) load failed for \(short)…: \(error)", category: logCategory)
                failure = .retryable(error)
            }
            fail(failure)
            return nil
        }
    }

    private func fail(_ failure: Failure) {
        hasReceivedBytes = false
        state = .failed(failure)
    }
}
