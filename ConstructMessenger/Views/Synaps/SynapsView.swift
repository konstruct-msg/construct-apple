//
//  SynapsView.swift
//  Construct Messenger
//
//  Synaps — persistent contact network, independent of chats.
//  Layout: Zoomable/pannable honeycomb cloud of round avatars.
//  Gestures: pinch-to-zoom + drag-to-pan. Contacts near the screen
//  center appear larger; peripheral contacts are dimmer — Apple Watch style.
//

import SwiftUI
import CoreData

// MARK: - SynapsView

struct SynapsView: View {

    @Environment(\.managedObjectContext) private var context
    @Environment(ChatsViewModel.self) private var chatsViewModel

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \User.displayName, ascending: true)],
        predicate: NSPredicate(format: "isContact == YES"),
        animation: .default
    )
    private var contacts: FetchedResults<User>

    @State private var searchText      = ""
    @State private var selectedContact: User? = nil
    @State private var pruneTarget:     User? = nil
    @State private var showPruneConfirm = false
    // Shared canvas transform — owned here so HoneycombCloud can read them for
    // the proximity effect while ZoomableCloud drives them via gestures.
    @State private var canvasScale:  CGFloat  = 0.85
    @State private var canvasOffset: CGSize   = .zero

    private var filtered: [User] {
        guard !searchText.isEmpty else { return Array(contacts) }
        let q = searchText.lowercased()
        return contacts.filter {
            $0.displayName.lowercased().contains(q) ||
            $0.username.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ZStack {
                    Color.Construct.bg.ignoresSafeArea()

                    if contacts.isEmpty {
                        emptyState
                    } else {
                        ZoomableCloud(
                            scale:    $canvasScale,
                            offset:   $canvasOffset,
                            minScale: 0.25,
                            maxScale: 3.0
                        ) {
                            HoneycombCloud(
                                contacts:     filtered,
                                selected:     $selectedContact,
                                canvasScale:  canvasScale,
                                canvasOffset: canvasOffset,
                                screenSize:   geo.size
                            )
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: LocalizedStringKey("synaps_search_prompt"))
            .onChange(of: searchText) { _, _ in
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    canvasScale  = 0.85
                    canvasOffset = .zero
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.Construct.bg2, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("SYNAPSES")
                        .font(ConstructFont.mono(13, weight: .semibold))
                        .foregroundStyle(Color.Construct.textBright)
                        .tracking(3)
                }
            }
            .sheet(item: $selectedContact) { user in
                UserProfileView(
                    user: user,
                    showMessageButton: true,
                    onOpenChat: { chatsViewModel.openOrCreateChat(with: user) },
                    onPrune: {
                        pruneTarget = user
                        showPruneConfirm = true
                    }
                )
                .environment(\.managedObjectContext, context)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
        .confirmationDialog(
            LocalizedStringKey("synaps_prune_title"),
            isPresented: $showPruneConfirm,
            titleVisibility: .visible
        ) {
            Button(LocalizedStringKey("synaps_prune_action"), role: .destructive) {
                if let user = pruneTarget {
                    chatsViewModel.pruneContact(userId: user.id)
                }
                pruneTarget = nil
            }
            Button(LocalizedStringKey("cancel"), role: .cancel) { pruneTarget = nil }
        } message: {
            if let name = pruneTarget?.displayName {
                Text(String(format: NSLocalizedString("synaps_prune_message", comment: ""), name))
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(Color.Construct.textDim)
            Text(LocalizedStringKey("synaps_empty_title"))
                .font(ConstructFont.display(17, weight: .semibold))
                .foregroundStyle(Color.Construct.textBright)
            Text(LocalizedStringKey("synaps_empty_subtitle"))
                .font(ConstructFont.display(14))
                .foregroundStyle(Color.Construct.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - ZoomableCloud (reusable container)

/// Wraps any content with simultaneous pinch-to-zoom and drag-to-pan gestures.
/// Exposes `scale` and `offset` as bindings so child views can read the current
/// transform for custom effects (e.g. proximity-based local scaling).
struct ZoomableCloud<Content: View>: View {
    @Binding var scale:  CGFloat
    @Binding var offset: CGSize
    var minScale: CGFloat = 0.25
    var maxScale: CGFloat = 3.0
    @ViewBuilder var content: () -> Content

    @State private var gestureScale:     CGFloat  = 1
    @State private var lastTranslation:  CGSize   = .zero

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                content()
                    .scaleEffect(scale, anchor: .center)
                    .offset(offset)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .simultaneousGesture(magnificationGesture(size: proxy.size))
            .simultaneousGesture(dragGesture(size: proxy.size))
        }
    }

    // MARK: Gestures

    private func magnificationGesture(size: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let delta = value / gestureScale
                gestureScale = value
                if abs(1 - delta) > 0.005 {
                    let newScale = scale * delta
                    scale = min(max(newScale, minScale), maxScale)
                }
            }
            .onEnded { _ in
                gestureScale = 1
                withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                    clampOffset(size: size)
                }
            }
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                let diff = CGSize(
                    width:  value.translation.width  - lastTranslation.width,
                    height: value.translation.height - lastTranslation.height
                )
                offset = CGSize(
                    width:  offset.width  + diff.width,
                    height: offset.height + diff.height
                )
                lastTranslation = value.translation
            }
            .onEnded { _ in
                lastTranslation = .zero
                withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                    clampOffset(size: size)
                }
            }
    }

    // Allow panning to see edge contacts (extra 20% margin) but prevent canvas
    // from flying completely off screen.
    private func clampOffset(size: CGSize) {
        let extraX = size.width  * 0.20
        let extraY = size.height * 0.20
        let maxX   = Swift.max(0, (size.width  * scale - size.width)  / 2 + extraX)
        let maxY   = Swift.max(0, (size.height * scale - size.height) / 2 + extraY)
        offset = CGSize(
            width:  min(max(offset.width,  -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
    }
}

// MARK: - Layout engine

/// Computes deterministic honeycomb positions for a flat contact list.
/// Even rows: `wideCols` circles. Odd rows: `wideCols - 1` circles, offset right
/// by half a cell — classic hex packing.
private struct HoneycombLayoutEngine {
    let contacts:   [User]
    let canvasWidth: CGFloat
    let wideCols = 4

    var cellWidth: CGFloat { canvasWidth / CGFloat(wideCols) }
    var cellSize:  CGFloat { cellWidth * 0.74 }
    var vStep:     CGFloat { cellWidth * 0.866 }  // √3/2

    struct Item: Identifiable {
        let id: String
        let user: User
        let position: CGPoint
    }

    var items: [Item] {
        var result: [Item] = []
        for (rowIdx, row) in rows.enumerated() {
            let xShift = rowIdx % 2 == 1 ? cellWidth / 2 : 0
            for (colIdx, user) in row.enumerated() {
                let cx = xShift + CGFloat(colIdx) * cellWidth + cellWidth / 2
                let cy = CGFloat(rowIdx) * vStep + cellWidth / 2
                result.append(Item(id: user.id, user: user, position: CGPoint(x: cx, y: cy)))
            }
        }
        return result
    }

    var totalHeight: CGFloat {
        CGFloat(rows.count) * vStep + cellWidth * 0.6
    }

    private var rows: [[User]] {
        var result: [[User]] = []
        var idx = 0, rowIdx = 0
        while idx < contacts.count {
            let n = rowIdx % 2 == 0 ? wideCols : wideCols - 1
            result.append(Array(contacts[idx ..< Swift.min(idx + n, contacts.count)]))
            idx += n; rowIdx += 1
        }
        return result
    }
}

// MARK: - Honeycomb Cloud

private struct HoneycombCloud: View {
    let contacts:     [User]
    @Binding var selected: User?
    let canvasScale:  CGFloat
    let canvasOffset: CGSize
    let screenSize:   CGSize

    var body: some View {
        GeometryReader { geo in
            let engine  = HoneycombLayoutEngine(contacts: contacts, canvasWidth: geo.size.width)
            let padding: CGFloat = 24
            let totalH  = engine.totalHeight + padding * 2

            ZStack(alignment: .topLeading) {
                Color.clear.frame(width: geo.size.width, height: totalH)

                ForEach(engine.items) { item in
                    let pos = CGPoint(x: item.position.x, y: item.position.y + padding)
                    ContactCircle(
                        user:         item.user,
                        size:         engine.cellSize,
                        canvasPos:    pos,
                        canvasScale:  canvasScale,
                        canvasOffset: canvasOffset,
                        screenSize:   screenSize
                    ) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) {
                            selected = item.user
                        }
                    }
                    .position(pos)
                }
            }
        }
    }
}

// MARK: - Contact Circle

private struct ContactCircle: View {
    @ObservedObject var user: User
    let size:         CGFloat
    let canvasPos:    CGPoint
    let canvasScale:  CGFloat
    let canvasOffset: CGSize
    let screenSize:   CGSize
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                if let data = user.avatarData, let img = PlatformImage(data: data) {
                    Image(platformImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Circle().fill(accentColor.opacity(0.18))
                    Text(initials)
                        .font(ConstructFont.mono(size * 0.26, weight: .semibold))
                        .foregroundStyle(accentColor)
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(borderColor, lineWidth: 1.5))
            .scaleEffect(proximityScale)
            .opacity(proximityOpacity)
        }
        .buttonStyle(.plain)
    }

    // MARK: Proximity effect
    //
    // Compute where this contact actually appears on screen after the canvas
    // transform (scaleEffect + offset). Contacts close to the screen centre
    // get a scale boost (≤ +30%) and full opacity; peripheral ones fade out.

    private var screenPos: CGPoint {
        let cx = screenSize.width  / 2
        let cy = screenSize.height / 2
        return CGPoint(
            x: (canvasPos.x - cx) * canvasScale + cx + canvasOffset.width,
            y: (canvasPos.y - cy) * canvasScale + cy + canvasOffset.height
        )
    }

    private var distanceToCenter: CGFloat {
        let c = CGPoint(x: screenSize.width / 2, y: screenSize.height / 2)
        return hypot(screenPos.x - c.x, screenPos.y - c.y)
    }

    /// Contacts within ~50% of the shortest screen half-dimension are "central".
    private var proximityScale: CGFloat {
        let radius = Swift.min(screenSize.width, screenSize.height) * 0.5
        let t = Swift.max(0, 1 - distanceToCenter / radius)
        return 1.0 + 0.30 * t
    }

    /// Peripheral contacts fade to 40% opacity.
    private var proximityOpacity: Double {
        let radius = Swift.min(screenSize.width, screenSize.height) * 0.65
        let t = Swift.max(0, 1 - distanceToCenter / radius)
        return 0.40 + 0.60 * t
    }

    // MARK: Style

    private var accentColor: Color { .hexagonAccent(for: user.id) }
    private var borderColor: Color {
        user.isBlocked ? Color.red.opacity(0.55) : Color.Construct.dim
    }

    private var initials: String {
        let words = user.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        switch words.count {
        case 0:  return "?"
        case 1:  return String(words[0].prefix(2)).uppercased()
        default: return (String(words[0].prefix(1)) + String(words[1].prefix(1))).uppercased()
        }
    }
}

// MARK: - Preview

#Preview("Honeycomb") {
    let container = PreviewHelpers.createPreviewContainer()
    let context = container.viewContext

    let users: [(String, String, String)] = [
        ("u1", "alice",   "Alice Wonderland"),
        ("u2", "bob",     "Bob Builder"),
        ("u3", "charlie", "Charlie Chaplin"),
        ("u4", "dave",    "Dave Villain"),
        ("u5", "eve",     "Eve Listener"),
        ("u6", "frank",   "Frank Ocean"),
        ("u7", "grace",   "Grace Hopper"),
        ("u8", "henry",   "Henry Ford"),
        ("u9", "iris",    "Iris Chang"),
        ("u10","james",   "James Webb"),
    ]
    for (id, username, name) in users {
        let user = PreviewHelpers.createSampleUser(context: context, id: id, username: username, displayName: name)
        user.isContact = true
        user.addedAt = Date()
    }
    let blocked = PreviewHelpers.createSampleUser(context: context, id: "u11", username: "blocked", displayName: "Blocked User")
    blocked.isContact = true
    blocked.isBlocked = true
    blocked.addedAt = Date()
    try? context.save()

    let chatsVM = ChatsViewModel()
    chatsVM.setContext(context)

    return SynapsView()
        .environment(\.managedObjectContext, context)
        .environment(chatsVM)
}

#Preview("Empty") {
    let container = PreviewHelpers.createPreviewContainer()
    let context = container.viewContext
    let chatsVM = ChatsViewModel()
    chatsVM.setContext(context)
    return SynapsView()
        .environment(\.managedObjectContext, context)
        .environment(chatsVM)
}
