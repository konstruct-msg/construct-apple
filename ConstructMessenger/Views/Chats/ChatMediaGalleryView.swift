//
//  ChatMediaGalleryView.swift
//  Construct Messenger
//
//  A chat's media (construct-docs todo 327): pictures and videos as a grid, files as a list.
//  Entered from the person's profile. A tile is the album bubble's own cell (`GridCell`), so it
//  loads, decrypts and plays as the bubble does; a tap opens the chat's full-screen viewer.
//

import SwiftUI

struct ChatMediaGalleryView: View {
    @State private var model: ChatMediaGalleryModel
    @State private var viewerStart: GalleryStartItem?

    init(chatId: String) {
        _model = State(initialValue: ChatMediaGalleryModel(chatId: chatId))
    }

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: ChatUIConstants.Media.albumTileGap),
        count: 3
    )

    var body: some View {
        VStack(spacing: .zero) {
            tabBar
            ZStack {
                if model.items.isEmpty, model.isComplete {
                    emptyState
                } else {
                    switch model.tab {
                    case .visual: grid
                    case .files: fileList
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.CT.bg.ignoresSafeArea())
        .screenTitle(NSLocalizedString("chat_media_title", comment: ""))
        .onAppear { if model.items.isEmpty, !model.isComplete { model.loadMore() } }
        #if os(iOS)
        .fullScreenCover(item: $viewerStart) { start in
            viewer(start)
        }
        #else
        .sheet(item: $viewerStart) { start in
            viewer(start)
        }
        #endif
    }

    // MARK: - Tabs

    /// Pictures or files — the system's segmented control.
    private var tabBar: some View {
        Picker(selection: Binding(get: { model.tab }, set: { model.select($0) })) {
            Text(NSLocalizedString("chat_media_tab_visual", comment: "")).tag(ChatMediaTab.visual)
            Text(NSLocalizedString("chat_media_tab_files", comment: "")).tag(ChatMediaTab.files)
        } label: {
            EmptyView()
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, CTLayout.edgePad)
        .padding(.vertical, CTLayout.inlinePad)
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: ChatUIConstants.Media.albumTileGap) {
                ForEach(model.items) { item in
                    if let row = model.row(item.messageId),
                       let content = parseMediaContent(from: row.legacyBody) {
                        tile(item, row: row, content: content)
                    }
                }
            }
        }
    }

    /// Square, cropped to fill — the bubble's album tile at the grid's size.
    private func tile(_ item: ChatMediaItem, row: TranscriptRow, content: MediaMessageContent) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GridCell(
                    mediaContent: content,
                    message: row,
                    itemIndex: item.item,
                    isPlaceholder: false,
                    extraCount: 0,
                    onTap: { viewerStart = GalleryStartItem(id: item.messageId, itemIndex: item.item) }
                )
            }
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(NSLocalizedString(item.kind == .photo ? "photo" : "video", comment: ""))
            .accessibilityAddTraits([.isImage, .isButton])
            .accessibilityAction { viewerStart = GalleryStartItem(id: item.messageId, itemIndex: item.item) }
            .onAppear { model.loadMoreIfNeeded(after: item) }
    }

    private func viewer(_ start: GalleryStartItem) -> some View {
        MediaGalleryViewer(
            messages: model.rowsOldestFirst,
            initialMessageId: start.messageId,
            initialItemIndex: start.itemIndex,
            isPresented: Binding(
                get: { viewerStart != nil },
                set: { if !$0 { viewerStart = nil } }
            )
        )
    }

    // MARK: - Files

    /// A message of files is the bubble the chat shows — download, open and play included —
    /// under the day it was sent.
    private var fileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: CTSpace.m) {
                ForEach(model.messageIds, id: \.self) { messageId in
                    if let row = model.row(messageId),
                       let files = MessageBubbleContentParsing.parseFileMessage(row.legacyBody) {
                        VStack(alignment: .leading, spacing: CTSpace.xs) {
                            Text(row.timestamp.formatted(date: .abbreviated, time: .shortened))
                                .font(CTFont.caption)
                                .foregroundStyle(Color.CT.textDim)
                            FileAttachmentBubbleView(
                                fileContent: files,
                                isSentByMe: row.isSentByMe,
                                source: PlaybackSource(chatId: row.chatId, messageId: row.id)
                            )
                        }
                        .onAppear { loadMoreIfLast(messageId) }
                    }
                }
            }
            .padding(.horizontal, CTLayout.edgePad)
            .padding(.vertical, CTSpace.m)
        }
    }

    private func loadMoreIfLast(_ messageId: String) {
        guard let last = model.items.last(where: { $0.messageId == messageId }) else { return }
        model.loadMoreIfNeeded(after: last)
    }

    // MARK: - Empty

    private var emptyState: some View {
        ContentUnavailableView {
            Label {
                Text(NSLocalizedString(
                    model.tab == .visual ? "chat_media_empty_visual" : "chat_media_empty_files",
                    comment: ""
                ))
                .font(CTFont.headline)
            } icon: {
                Image(systemName: model.tab == .visual ? "photo.on.rectangle" : "doc")
            }
        }
    }
}
