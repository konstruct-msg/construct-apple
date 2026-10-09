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
        let container = PersistenceController(inMemory: true).container
        context = container.viewContext
        // The placeholders are written through the repositories (messages B1); point them here.
        LocalRepositories.useMessagesForTesting(container)
        LocalRepositories.useChatsForTesting(container)
    }

    override func tearDown() {
        LocalRepositories.useMessagesForTesting(nil)
        LocalRepositories.useChatsForTesting(nil)
        context = nil
        super.tearDown()
    }

    /// A saved chat: the repository finds it by id in its own context.
    private func makeChat() -> Chat {
        let chat = Chat(context: context)
        chat.id = UUID().uuidString
        chat.unreadCount = 0
        try! context.save()
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
              let parsed = parseMediaContent(from: message.legacyBody) else {
            return XCTFail("Placeholder did not parse as media content")
        }
        XCTAssertEqual(parsed.caption, "album")
        XCTAssertEqual(parsed.mediaItems.count, 3, "An album must show one cell per attachment while uploading")
        XCTAssertTrue(parsed.mediaItems.allSatisfy { ($0["_placeholder"] as? Bool) == true })
        // The MIME type drives the video cell, so a video must not render as an empty photo.
        XCTAssertEqual(parsed.mediaItems[1]["mediaType"] as? String, "video/mp4")
    }

    /// Files being sent are one row each, by name and size, as the file bubble will be — not one
    /// empty photo cell captioned with the first name (TODO 10). A name with a tab or quotes
    /// still parses: a body that does not parse is drawn as text.
    /// Mutation: pass a single empty item again — one cell, no names.
    /// Mutation: escape by hand without control characters — the tab breaks the JSON.
    func testAFilePlaceholderHasOneNamedRowPerFile() {
        let chat = makeChat()
        let odd = "notes\tv2 \"final\".txt"

        service.savePlaceholderMessage(
            id: UUID().uuidString,
            fromUserId: UUID().uuidString,
            toUserId: UUID().uuidString,
            caption: "",
            items: [.init(fileName: "report.pdf", fileSize: 2048), .init(fileName: odd, fileSize: nil)],
            replyTo: nil,
            chat: chat,
            in: context
        )

        guard let message = visibleMessages(in: chat).first,
              let parsed = parseMediaContent(from: message.legacyBody) else {
            return XCTFail("File placeholder did not parse as media content")
        }
        XCTAssertEqual(parsed.mediaItems.map { $0["fileName"] as? String }, ["report.pdf", odd])
        XCTAssertEqual(parsed.mediaItems[0]["size"] as? Int, 2048)
        XCTAssertEqual(parsed.caption, "", "the caption is the person's, not a file name")
        XCTAssertTrue(UploadPlaceholderBody.isSentinel(message.legacyBody ?? ""))
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

        let parsed = visibleMessages(in: chat).first.flatMap { parseMediaContent(from: $0.legacyBody) }
        XCTAssertEqual(parsed?.caption, #"say "hi" \ ok"#)
    }

    /// The body the upload writers actually store. Retry rebuilds a text message from any
    /// non-empty `.regular` row; these two must not be one.
    func testUploadPlaceholderIsNotRecoverableAsText() {
        let chat = makeChat()
        let from = UUID().uuidString
        let to = UUID().uuidString

        service.savePlaceholderMessage(
            id: UUID().uuidString,
            fromUserId: from,
            toUserId: to,
            caption: "",
            items: [MessagePersistenceService.UploadPlaceholderItem()],
            replyTo: nil,
            chat: chat,
            in: context
        )
        service.saveVoicePlaceholderMessage(
            id: UUID().uuidString,
            fromUserId: from,
            toUserId: to,
            duration: 1.5,
            waveform: [0.2, 0.8],
            chat: chat,
            in: context
        )

        let rows = visibleMessages(in: chat)
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            XCTAssertTrue(UploadPlaceholderBody.isSentinel(row.legacyBody), row.legacyBody)
            XCTAssertNil(
                MessageRetryManager.recoverWirePlaintext(for: row),
                "retry would send this JSON as the message text"
            )
        }
    }
}
