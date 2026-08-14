//
//  ScrollPositionSpikeView.swift
//  Construct Messenger
//
//  PR-0 of the chat viewport migration — see
//  ~/Code/construct-docs/client/ios/CHAT_VIEWPORT_MIGRATION.md
//
//  DELETE THIS FILE once the three questions are answered and written into
//  decisions/chat-viewport-owned-inset. It is a measuring instrument, not a feature.
//
//  Why it exists: `.scrollPosition(id:)` appears nowhere in this repository, yet the migration
//  hangs history hold, prepend, and the only mitigation for the history-yank risk on it. Worse,
//  it and `.defaultScrollAnchor(.bottom)` are both applied to the same ScrollView and both claim
//  the position — the very "one meaning, two carriers" shape the migration argues against.
//  Deployment 18.5+ proves the symbol exists; it says nothing about who wins.
//
//  This answers with numbers rather than an impression: the bound row reports its own on-screen
//  Y, so "did it hold" is a subtraction, not a judgement.
//

#if DEBUG
import SwiftUI

/// Reachable from Diagnostics ▸ SCROLL POSITION SPIKE. Orange on purpose (debug-only UI).
struct ScrollPositionSpikeView: View {
    @Environment(\.dismiss) private var dismiss

    private struct SpikeRow: Identifiable, Equatable {
        let id: Int
        let height: CGFloat
    }

    /// Eager stack, variable heights, same order of magnitude as a chat window (30 + 20 prepend).
    @State private var rows: [SpikeRow] = (0..<30).map {
        SpikeRow(id: $0, height: 40 + CGFloat(($0 * 37) % 180))
    }
    @State private var nextPrependId = -1

    @State private var boundId: Int?
    @State private var pad: CGFloat = 100

    /// On-screen Y of the bound row, in the scroll container's coordinate space.
    /// This is the whole measurement: if it does not move when `pad` changes, the bound id won.
    @State private var boundRowY: CGFloat?
    @State private var markY: CGFloat?

    private let space = "scrollSpike"

    var body: some View {
        VStack(spacing: 0) {
            CTNavBar(
                title: "SCROLL SPIKE",
                showBack: true,
                backAction: { dismiss() }
            )
            readout
            scroll
            controls
        }
        .ctBackground()
    }

    // MARK: - The stack under test

    private var scroll: some View {
        ScrollView {
            VStack(spacing: 8) {                       // eager — not Lazy, that is the point
                ForEach(rows) { row in
                    rowView(row)
                        .id(row.id)
                }
            }
            .padding(.bottom, pad)
        }
        .coordinateSpace(name: space)
        .defaultScrollAnchor(.bottom)
        .scrollPosition(id: $boundId)
        .border(.orange)
    }

    private func rowView(_ row: SpikeRow) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: CTRadius.card)
                .fill(row.id == boundId ? Color.orange.opacity(0.35) : Color.CT.bgMsg)
            Text("\(row.id) · h\(Int(row.height))")
                .font(CTFont.regular(12))
                .foregroundStyle(Color.CT.text)
        }
        .frame(height: row.height)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .named(space)).minY
        } action: { y in
            if row.id == boundId { boundRowY = y }
            if row.id == 0 { markY = y }
        }
    }

    // MARK: - Readout

    private var readout: some View {
        VStack(alignment: .leading, spacing: 2) {
            line("bound", boundId.map(String.init) ?? "nil")
            line("bound row Y", boundRowY.map { String(format: "%.1f", $0) } ?? "—")
            line("row 0 Y", markY.map { String(format: "%.1f", $0) } ?? "—")
            line("pad", String(format: "%.0f", pad))
            line("rows", "\(rows.count)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(CTLayout.edgePad)
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Color.CT.textDim)
            Spacer()
            Text(value).foregroundStyle(.orange)
        }
        .font(CTFont.regular(12))
    }

    // MARK: - The three questions

    private var controls: some View {
        VStack(spacing: 8) {
            // Q1 — does a bound row hold its place when the bottom pad grows?
            HStack(spacing: 8) {
                button("pad +40") { snapshot("Q1 pad+40 before"); pad += 40 }
                button("pad −40") { snapshot("Q1 pad-40 before"); pad = max(0, pad - 40) }
                button("read") { snapshot("Q1 after") }
            }
            // Q2 — what does binding / unbinding itself do?
            HStack(spacing: 8) {
                button("bind 15") { snapshot("Q2 nil→id before"); boundId = 15 }
                button("unbind") { snapshot("Q2 id→nil before"); boundId = nil }
            }
            // Q3 — is a prepend visible while bound?
            button("prepend 20 rows") {
                snapshot("Q3 prepend before")
                let new = (0..<20).map { i -> SpikeRow in
                    let id = nextPrependId - i
                    return SpikeRow(id: id, height: 40 + CGFloat((abs(id) * 53) % 180))
                }
                nextPrependId -= 20
                rows.insert(contentsOf: new.reversed(), at: 0)
            }
        }
        .padding(CTLayout.edgePad)
    }

    private func button(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(CTFont.medium(12))
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity)
                .frame(height: CTLayout.controlHeight)
                .background(CTShape.control().stroke(.orange.opacity(0.5)))
        }
    }

    /// One greppable line per action: `SCROLL_SPIKE`.
    private func snapshot(_ tag: String) {
        Log.debug(
            "SCROLL_SPIKE \(tag) bound=\(boundId.map(String.init) ?? "nil") "
            + "boundY=\(boundRowY.map { String(format: "%.1f", $0) } ?? "—") "
            + "row0Y=\(markY.map { String(format: "%.1f", $0) } ?? "—") "
            + "pad=\(Int(pad)) rows=\(rows.count)",
            category: "ScrollSpike"
        )
    }
}
#endif
