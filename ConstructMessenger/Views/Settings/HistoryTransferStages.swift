//
//  HistoryTransferStages.swift
//  Construct Messenger
//
//  What a history transfer shows while it runs, on either device: the two devices, one title
//  saying where it is, and the step under way — what is done and what comes next said in
//  words. Until 2026-10-25 each stage was a row with a mark, and a stage not yet begun was an
//  empty circle, which reads as something to tap.
//  The phase is `HistoryTransferCoordinator`'s; this file only reads it.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum HistoryTransferStage: CaseIterable {
    case chats
    case media

    var titleKey: String {
        switch self {
        case .chats: return "history_sync_stage_chats"
        case .media: return "history_sync_stage_media"
        }
    }
}

enum HistoryTransferSide {
    case sending
    case receiving
}

/// Everything the transfer screen says for one phase. Pure, so a test can walk every phase.
struct HistoryTransferScreen: Equatable {
    enum Picture: Equatable {
        /// The other device has not answered yet.
        case looking
        /// …and has not for `HistoryTransferSendView.notSeenAfter`.
        case notSeen
        case moving
        case done
        /// Finished, but not everything arrived.
        case incomplete
        case stopped
    }

    struct Step: Equatable {
        let stage: HistoryTransferStage
        let number: Int
        let count: Int
        let nextKey: String?
    }

    var picture: Picture
    var titleKey: String
    var bodyKey: String?
    /// A stage already finished, said above the one under way.
    var doneKey: String?
    var step: Step?
    /// Said at the foot of the screen, above its actions.
    var footerKey: String?

    /// `stages` narrows a Settings retry to the one it sends. `localNetworkDenied`: the system
    /// refuses this app the local network, so nothing is found until the person allows it.
    static func of(
        phase: HistoryTransferPhase,
        side: HistoryTransferSide,
        stages: [HistoryTransferStage] = HistoryTransferStage.allCases,
        peerNotSeen: Bool = false,
        localNetworkDenied: Bool = false
    ) -> HistoryTransferScreen {
        let chatsDone = stages.contains(.chats) ? "history_sync_chats_done" : nil
        func step(_ stage: HistoryTransferStage) -> Step? {
            guard let index = stages.firstIndex(of: stage) else { return nil }
            let next = stage == .chats && stages.contains(.media) ? "history_sync_next_media" : nil
            return Step(stage: stage, number: index + 1, count: stages.count, nextKey: next)
        }

        switch phase {
        case .idle where localNetworkDenied:
            return HistoryTransferScreen(
                picture: .notSeen, titleKey: "history_sync_title_local_network",
                bodyKey: Self.localNetworkBodyKey
            )
        case .idle:
            switch side {
            case .receiving:
                return HistoryTransferScreen(
                    picture: .looking, titleKey: "history_sync_title_waiting", bodyKey: "history_sync_body_waiting"
                )
            case .sending where peerNotSeen:
                return HistoryTransferScreen(
                    picture: .notSeen, titleKey: "history_sync_title_not_seen",
                    bodyKey: "history_sync_body_not_seen", footerKey: "history_sync_footer_file"
                )
            case .sending:
                return HistoryTransferScreen(
                    picture: .looking, titleKey: "history_sync_looking", bodyKey: "history_sync_body_looking",
                    footerKey: stages.count > 1 ? "history_sync_footer_order" : nil
                )
            }
        case .transcript:
            return HistoryTransferScreen(
                picture: .moving,
                titleKey: side == .sending ? "history_sync_title_sending_chats" : "history_sync_title_receiving_chats",
                step: step(.chats), footerKey: "history_sync_footer_keep_open"
            )
        // The receiver marks chats done and media started in one step; the sender opens the
        // media connection right after the chats one closes.
        case .chatsTransferred, .media:
            return HistoryTransferScreen(
                picture: .moving,
                titleKey: side == .sending ? "history_sync_title_sending_media" : "history_sync_title_receiving_media",
                doneKey: chatsDone, step: step(.media), footerKey: "history_sync_footer_keep_open"
            )
        case .complete:
            return HistoryTransferScreen(picture: .done, titleKey: "history_sync_done")
        // The media retry lives on the device that has the history.
        case .mediaIncomplete:
            return HistoryTransferScreen(
                picture: .incomplete, titleKey: "history_sync_title_media_incomplete",
                bodyKey: side == .sending ? "history_sync_body_media_retry_here" : "history_sync_body_media_retry_other",
                doneKey: chatsDone
            )
        case .saveFileInstead:
            return HistoryTransferScreen(
                picture: .stopped, titleKey: "history_sync_title_stopped", bodyKey: "history_sync_body_file"
            )
        case .skipped:
            return HistoryTransferScreen(picture: .done, titleKey: "history_sync_skip_sending")
        }
    }

    /// Where the Local Network switch is, named the way this system names it.
    #if os(macOS)
    static let localNetworkBodyKey = "history_sync_body_local_network_mac"
    #else
    static let localNetworkBodyKey = "history_sync_body_local_network"
    #endif

    /// Every key this screen can show, for the tests that read them back.
    var keys: [String] {
        [titleKey, bodyKey, doneKey, step?.stage.titleKey, step?.nextKey, footerKey].compactMap { $0 }
    }
}

/// Opens where the Local Network permission is switched: this app's page in Settings on iOS,
/// the Local Network list in System Settings on a Mac.
struct HistoryLocalNetworkSettingsButton: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        CTSectionGroup {
            ConstructButtonRow(
                systemImage: "gearshape",
                title: LocalizedStringKey("history_sync_open_settings")
            ) {
                if let url = Self.settingsURL { openURL(url) }
            }
        }
    }

    #if os(macOS)
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
    #else
    static let settingsURL = URL(string: UIApplication.openSettingsURLString)
    #endif
}

/// The transfer screen's frame: the status in the middle, the footer and `actions` at the foot.
/// Scrolls when the text outgrows the screen (large Dynamic Type).
struct HistoryTransferLayout<Actions: View>: View {
    let screen: HistoryTransferScreen
    let side: HistoryTransferSide
    /// The media phase's bytes, when it is under way: a filling bar and what is left.
    var progress: HistoryTransferProgress? = nil
    @ViewBuilder var actions: Actions

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: CTLayout.sectionGap) {
                    Spacer(minLength: CTSpace.xl)
                    HistoryTransferStatus(screen: screen, side: side, progress: progress)
                    Spacer(minLength: CTSpace.xl)
                    if let footer = screen.footerKey {
                        Text(NSLocalizedString(footer, comment: ""))
                            .font(CTFont.secondary)
                            .foregroundStyle(Color.CT.textDim)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity)
                    }
                    actions
                }
                .padding(CTLayout.edgePad)
                .frame(minHeight: proxy.size.height)
            }
        }
        .background(Color.CT.bg.ignoresSafeArea())
    }
}

/// The picture, the title and the step under way.
private struct HistoryTransferStatus: View {
    let screen: HistoryTransferScreen
    let side: HistoryTransferSide
    let progress: HistoryTransferProgress?

    var body: some View {
        VStack(spacing: CTSpace.xl) {
            HistoryTransferPicture(picture: screen.picture, side: side)
            VStack(spacing: CTSpace.s) {
                Text(NSLocalizedString(screen.titleKey, comment: ""))
                    .font(CTFont.title)
                    .foregroundStyle(Color.CT.text)
                if let body = screen.bodyKey {
                    Text(NSLocalizedString(body, comment: ""))
                        .font(CTFont.body)
                        .foregroundStyle(Color.CT.textDim)
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            if screen.doneKey != nil || screen.step != nil {
                stepBlock
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Leading under a step; a done line with nothing under way stands centred like the title.
    private var stepBlock: some View {
        VStack(alignment: screen.step == nil ? .center : .leading, spacing: CTSpace.s) {
            if let done = screen.doneKey {
                Label {
                    Text(NSLocalizedString(done, comment: ""))
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.CT.accent)
                }
                .font(CTFont.body)
                .foregroundStyle(Color.CT.textDim)
            }
            if let step = screen.step {
                HStack {
                    Text(NSLocalizedString(step.stage.titleKey, comment: ""))
                        .foregroundStyle(Color.CT.text)
                    Spacer()
                    if step.count > 1 {
                        Text(String(format: NSLocalizedString("history_sync_step_of", comment: ""), step.number, step.count))
                            .foregroundStyle(Color.CT.textDim)
                    }
                }
                .font(CTFont.body)
                .accessibilityElement(children: .combine)
                if step.stage == .media, let progress, progress.totalBytes > 0 {
                    HistoryTransferAmount(progress: progress)
                } else {
                    HistoryTransferBar()
                }
                if let next = step.nextKey {
                    Text(NSLocalizedString(next, comment: ""))
                        .font(CTFont.secondary)
                        .foregroundStyle(Color.CT.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: screen.step == nil ? .center : .leading)
    }
}

/// The two devices with what is happening between them, or the outcome in their place. The
/// sender is on the left on both screens, so the arrow always points the way history goes.
private struct HistoryTransferPicture: View {
    let picture: HistoryTransferScreen.Picture
    let side: HistoryTransferSide

    /// How far the other device fades while it has not been found.
    private static let unseenOpacity = 0.4

    var body: some View {
        Group {
            switch picture {
            case .done:
                outcome("checkmark.circle.fill", Color.CT.accent)
            case .incomplete:
                outcome("exclamationmark.circle.fill", Color.CT.warning)
            case .stopped:
                outcome("exclamationmark.circle.fill", Color.CT.danger)
            case .looking, .notSeen, .moving:
                HStack(alignment: .center, spacing: CTSpace.l) {
                    if side == .sending { this; connector; other } else { other; connector; this }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func outcome(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol)
            .font(CTIcon.font(CTIcon.hero))
            .foregroundStyle(color)
    }

    private var this: some View {
        device(Self.thisSymbol, "history_sync_device_this", seen: true)
    }

    private var other: some View {
        device(Self.otherSymbol, "history_sync_device_other", seen: picture == .moving)
    }

    private func device(_ symbol: String, _ labelKey: String, seen: Bool) -> some View {
        VStack(spacing: CTSpace.s) {
            Image(systemName: symbol)
                .font(CTIcon.font(CTIcon.hero, weight: .light))
                .foregroundStyle(Color.CT.text)
                .opacity(seen ? 1 : Self.unseenOpacity)
            Text(NSLocalizedString(labelKey, comment: ""))
                .font(CTFont.caption)
                .foregroundStyle(Color.CT.textDim)
        }
    }

    @ViewBuilder
    private var connector: some View {
        switch picture {
        case .moving:
            Image(systemName: "arrow.right")
                .font(CTIcon.font(CTIcon.control))
                .foregroundStyle(Color.CT.accent)
                .symbolEffect(.pulse)
        case .looking:
            Image(systemName: "ellipsis")
                .font(CTIcon.font(CTIcon.control))
                .foregroundStyle(Color.CT.accent)
                .symbolEffect(.variableColor.iterative)
        default:
            Image(systemName: "ellipsis")
                .font(CTIcon.font(CTIcon.control))
                .foregroundStyle(Color.CT.textDim)
        }
    }

    #if os(macOS)
    private static let thisSymbol = "laptopcomputer"
    private static let otherSymbol = "iphone"
    #else
    private static let thisSymbol = "iphone"
    /// Unknown: a phone, an iPad or a computer. A phone is the common case.
    private static let otherSymbol = "iphone"
    #endif
}

/// The media phase with its amount: a bar that fills, how much of how much, and the time left at
/// the rate so far — once there is a rate to go by. Ticks each second so the estimate moves
/// between the percent steps the coordinator publishes.
private struct HistoryTransferAmount: View {
    let progress: HistoryTransferProgress

    private static let height: CGFloat = 6

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: CTSpace.s) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(Color.CT.noise)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(Color.CT.accent)
                                .frame(width: proxy.size.width * progress.fraction)
                        }
                        .clipShape(Capsule())
                }
                .frame(height: Self.height)
                .animation(.linear(duration: 0.3), value: progress.fraction)
                Text(Self.caption(progress, now: context.date))
                    .font(CTFont.secondary)
                    .foregroundStyle(Color.CT.textDim)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(Self.caption(progress, now: context.date)))
            .accessibilityValue(Text(progress.fraction.formatted(.percent.precision(.fractionLength(0)))))
        }
    }

    static func caption(_ progress: HistoryTransferProgress, now: Date) -> String {
        let amount = String(
            format: NSLocalizedString("history_sync_amount", comment: ""),
            ByteCountFormatter.string(fromByteCount: Int64(progress.doneBytes), countStyle: .file),
            ByteCountFormatter.string(fromByteCount: Int64(progress.totalBytes), countStyle: .file)
        )
        guard let seconds = progress.secondsLeft(now: now) else { return amount }
        let left = HistoryTransferProgress.timeLeft(seconds: seconds)
        return amount + " · " + String(format: NSLocalizedString(left.key, comment: ""), left.value)
    }
}

/// Progress with no amount: the chats phase, which reports its phase, not how much of it is done.
/// A segment runs along the track; with Reduce Motion it stands still.
private struct HistoryTransferBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position: CGFloat = Self.start

    private static let height: CGFloat = 6
    /// Share of the track the segment covers.
    private static let segment: CGFloat = 0.35
    private static let start: CGFloat = -segment
    private static let still: CGFloat = 0.3
    private static let lap: Double = 1.4

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(Color.CT.noise)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Color.CT.accent)
                        .frame(width: proxy.size.width * Self.segment)
                        .offset(x: proxy.size.width * position)
                }
                .clipShape(Capsule())
        }
        .frame(height: Self.height)
        .onAppear {
            if reduceMotion {
                position = Self.still
            } else {
                withAnimation(.linear(duration: Self.lap).repeatForever(autoreverses: false)) { position = 1 }
            }
        }
        .accessibilityHidden(true)
    }
}
