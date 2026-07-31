import XCTest
import CoreData
@testable import Construct_Messenger

/// Regression cover for media/voice/file upload placeholders being invisible in the transcript.
///
/// `ChatMessageStore` fetches the transcript with `controlMessageFilterPredicate`, which
/// requires `contentTypeRaw == 0` (`.regular`). The upload placeholders were stamped
/// `.media` (raw 2), so the rows existed in Core Data but were fetched by nothing: the
/// bubble with the local thumbnail and the percentage badge never appeared, and the media
/// only showed up once the upload finished and the real `.regular` message replaced the
/// placeholder. That is the whole "media only appears after it's sent" symptom.
///
/// `MessageContentType.infer` deliberately maps media payloads to `.regular` for this exact
/// reason, so anything that writes `.media` by hand is writing an invisible row.
@MainActor
final class UploadPlaceholderVisibilityTests: XCTestCase {
    private var context: NSManagedObjectContext!
    private let service = MessagePersistenceService()

    override func setUp() {
        super.setUp()
        context = PersistenceController(inMemory: true).container.viewContext
    }

    override func tearDown() {
        context = nil
        super.tearDown()
    }

    private func makeChat() -> Chat {
        let chat = Chat(context: context)
        chat.id = UUID().uuidString
        chat.unreadCount = 0
        return chat
    }

    /// Fetch the chat's transcript exactly the way `ChatMessageStore` does.
    private func visibleMessages(in chat: Chat) -> [Message] {
        let request = Message.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "chat == %@", chat),
            ChatMessageStore.controlMessageFilterPredicate
        ])
        return ((try? context.fetch(request)) ?? []).filter {
            !$0.isControlArtifact && !$0.isServiceArtifact
        }
    }

    func testMediaPlaceholderIsVisibleInTranscript() {
        let chat = makeChat()
        let id = UUID().uuidString

        service.savePlaceholderMessage(
            id: id,
            fromUserId: UUID().uuidString,
            toUserId: UUID().uuidString,
            caption: "hello",
            items: [MessagePersistenceService.UploadPlaceholderItem(mimeType: "image/jpeg")],
            replyTo: nil,
            chat: chat,
            in: context
        )

        let visible = visibleMessages(in: chat)
        XCTAssertEqual(visible.count, 1, "Upload placeholder must be fetched by the transcript FRC")
        XCTAssertEqual(visible.first?.deliveryStatus, .sending)
    }

    func testVoicePlaceholderIsVisibleInTranscript() {
        let chat = makeChat()

        service.saveVoicePlaceholderMessage(
            id: UUID().uuidString,
            fromUserId: UUID().uuidString,
            toUserId: UUID().uuidString,
            duration: 3.5,
            waveform: [0.1, 0.9, 0.4],
            chat: chat,
            in: context
        )

        XCTAssertEqual(visibleMessages(in: chat).count, 1,
                       "Voice upload placeholder must be fetched by the transcript FRC")
    }

    /// The placeholder must parse as media so `MediaMessageView` renders it (with the
    /// upload badge) instead of a raw-text bubble showing the sentinel JSON.
    func testPlaceholderParsesAsMediaWithOneCellPerAttachment() {
        let chat = makeChat()

        service.savePlaceholderMessage(
            id: UUID().uuidString,
            fromUserId: UUID().uuidString,
            toUserId: UUID().uuidString,
            caption: "album",
            items: [
                .init(mimeType: "image/jpeg"),
                .init(mimeType: "video/mp4"),
                .init(mimeType: "image/heic")
            ],
            replyTo: nil,
            chat: chat,
            in: context
        )

        guard let message = visibleMessages(in: chat).first,
              let parsed = parseMediaContent(from: message.displayText) else {
            return XCTFail("Placeholder did not parse as media content")
        }
        XCTAssertEqual(parsed.caption, "album")
        XCTAssertEqual(parsed.mediaItems.count, 3, "An album must show one cell per attachment while uploading")
        XCTAssertTrue(parsed.mediaItems.allSatisfy { ($0["_placeholder"] as? Bool) == true })
        // The MIME type drives the video cell, so a video must not render as an empty photo.
        XCTAssertEqual(parsed.mediaItems[1]["mediaType"] as? String, "video/mp4")
    }

    /// A caption containing quotes/backslashes must not break the hand-built sentinel JSON.
    func testPlaceholderCaptionIsEscaped() {
        let chat = makeChat()

        service.savePlaceholderMessage(
            id: UUID().uuidString,
            fromUserId: UUID().uuidString,
            toUserId: UUID().uuidString,
            caption: #"say "hi" \ ok"#,
            items: [MessagePersistenceService.UploadPlaceholderItem()],
            replyTo: nil,
            chat: chat,
            in: context
        )

        let parsed = visibleMessages(in: chat).first.flatMap { parseMediaContent(from: $0.displayText) }
        XCTAssertEqual(parsed?.caption, #"say "hi" \ ok"#)
    }
}
