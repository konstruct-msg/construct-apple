//
//  NowPlayingBanner.swift
//  Construct Messenger
//
//  The track that keeps playing: a card above the bars, on every screen, its own chat too.
//  Pause, stop, and a tap that goes back to the message. The shape is the room
//  banner's from the room concept (deferred past release 1), so the room can take this place.
//

import SwiftUI

struct NowPlayingBanner: View {
    /// Opens the track's chat at its message.
    let onOpen: (PlaybackSource) -> Void

    @ObservedObject private var player = AudioPlayerService.shared

    init(onOpen: @escaping (PlaybackSource) -> Void) {
        self.onOpen = onOpen
    }

    private static let appearance = Animation.easeInOut(duration: 0.2)

    var body: some View {
        let shown = player.source != nil
        VStack(spacing: 0) {
            if shown, let source = player.source {
                card(source)
                    .padding(.horizontal, CTLayout.edgePad)
                    .padding(.vertical, CTSpace.xs)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Self.appearance, value: shown)
    }

    private func card(_ source: PlaybackSource) -> some View {
        let playing = !player.isPaused
        return VStack(spacing: CTSpace.xs) {
            HStack(spacing: CTSpace.s) {
                Button {
                    _ = player.toggleCurrent()
                } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(CTIcon.font(CTIcon.row, weight: .semibold))
                        .foregroundStyle(Color.CT.accent)
                        .frame(width: CTLayout.hitTarget, height: CTLayout.hitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(NSLocalizedString(playing ? "audio_pause" : "audio_play", comment: "")))

                Button { onOpen(source) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.fileName ?? NSLocalizedString("voice_message", comment: ""))
                            .font(CTFont.ui(13, weight: .medium))
                            .foregroundStyle(Color.CT.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(chatName(source.chatId)) · \(formatMediaDuration(player.elapsed))")
                            .font(CTFont.caption)
                            .foregroundStyle(Color.CT.textDim)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text(NSLocalizedString("now_playing_open_hint", comment: "")))

                Button { player.stop() } label: {
                    Image(systemName: "xmark")
                        .font(CTIcon.font(CTIcon.caption, weight: .semibold))
                        .foregroundStyle(Color.CT.textDim)
                        .frame(width: CTLayout.hitTarget, height: CTLayout.hitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(NSLocalizedString("audio_stop", comment: "")))
            }
            ProgressView(value: player.progress)
                .progressViewStyle(.linear)
                .tint(Color.CT.accent)
                .padding(.horizontal, CTSpace.m)
                .accessibilityHidden(true)
        }
        .padding(.bottom, CTSpace.s)
        .background(Color.CT.bgMsg, in: CTShape.control())
        .overlay(CTShape.control().stroke(Color.CT.accentDim, lineWidth: 1))
    }

    /// The person the chat is with, as the chat list names them.
    private func chatName(_ chatId: String) -> String {
        guard let peerId = ChatsLive.shared.chat(chatId)?.peerId else { return "" }
        return ContactsLive.shared.contact(peerId)?.resolvedDisplayName ?? DisplayNameGenerator.generate(from: peerId)
    }
}
