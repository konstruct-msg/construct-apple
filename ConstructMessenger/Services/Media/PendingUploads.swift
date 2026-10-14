import Foundation

/// What an upload placeholder was made from, so its retry can run again — from whichever chat
/// screen shows the row. Until 2026-10-14 this lived in the chat's own `ChatSendCoordinator`: an
/// upload kept running after the chat was closed, but if it then failed, the retry on the
/// reopened chat (a new coordinator) found nothing and the files were lost.
///
/// In memory only. A placeholder that outlives the process is retired at launch (`StuckSend`),
/// and a picked file's URL would not be readable in the next one anyway.
@MainActor
final class PendingUploads {
    static let shared = PendingUploads()

    struct Payload {
        let attachments: [MediaAttachment]
        let fileURLs: [URL]
        let caption: String
        let replyTo: TranscriptRow?
    }

    private var payloads: [String: Payload] = [:]

    init() {}

    func store(_ payload: Payload, for placeholderId: String) {
        payloads[placeholderId] = payload
    }

    /// The upload ended — sent, or never to be retried.
    func remove(_ placeholderId: String) {
        payloads[placeholderId] = nil
    }

    /// The payload, handed over once: a retry takes it, and a second tap finds nothing.
    func take(_ placeholderId: String) -> Payload? {
        payloads.removeValue(forKey: placeholderId)
    }
}
