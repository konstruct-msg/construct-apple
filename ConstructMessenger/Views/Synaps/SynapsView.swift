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
    @State private var canvasScale:  CGFloat  = 1.0   // recalculated on appear
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
            VStack(spacing: 0) {
                synapsNavBar
                synapsSearchBar
                GeometryReader { geo in
                    ZStack {
                        Color.CT.bg.ignoresSafeArea()
                        CTMatrixBackground().ignoresSafeArea()

                        if contacts.isEmpty {
                            emptyState
                        } else {
                            ZoomableCloud(
                                scale:    $canvasScale,
                                offset:   $canvasOffset,
                                minScale: 0.20,
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
                    .onAppear {
                        canvasScale = fitScale(contacts: Array(contacts), screenSize: geo.size)
                    }
                }
            }
            .onChange(of: searchText) { _, _ in
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    canvasOffset = .zero
                }
            }
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
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

    // MARK: - Initial scale

    /// Compute a zoom level that fits all contacts with ~12% breathing room.
    private func fitScale(contacts: [User], screenSize: CGSize) -> CGFloat {
        guard !contacts.isEmpty else { return 1.0 }
        let engine = HoneycombLayoutEngine(contacts: contacts, canvasSize: screenSize)
        return engine.initialScale
    }

    // MARK: - Nav Bar

    private var synapsNavBar: some View {
        CTNavBar(title: NSLocalizedString("synaps", comment: ""))
    }

    // MARK: - Search Bar

    private var synapsSearchBar: some View {
        HStack(spacing: 6) {
            Text("[")
                .font(CTFont.regular(13))
                .foregroundColor(Color.CT.textDim)
            TextField("", text: $searchText, prompt: Text(LocalizedStringKey("synaps_search_prompt"))
                .font(CTFont.regular(13))
                .foregroundColor(Color.CT.textDim))
                .font(CTFont.regular(13))
                .foregroundColor(Color.CT.text)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .tint(Color.CT.accent)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Text("×")
                        .font(CTFont.regular(13))
                        .foregroundColor(Color.CT.textDim)
                }
            } else {
                Text("]")
                    .font(CTFont.regular(13))
                    .foregroundColor(Color.CT.textDim)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.CT.bgMsg)
        .ctBorderBottom()
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Text(LocalizedStringKey("synaps_empty_title"))
                .font(CTFont.bold(17))
                .foregroundStyle(Color.CT.text)
            Text(LocalizedStringKey("synaps_empty_subtitle"))
                .font(CTFont.regular(14))
                .foregroundStyle(Color.CT.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - ZoomableCloud, HoneycombLayoutEngine, ContactMetrics
// → moved to SynapsLayoutEngine.swift (shared with DesktopSynapsView)

// MARK: - Honeycomb Cloud

private struct HoneycombCloud: View {
    let contacts:     [User]
    @Binding var selected: User?
    let canvasScale:  CGFloat
    let canvasOffset: CGSize
    let screenSize:   CGSize

    // MARK: Activity metrics

    /// Message count per contact (raw), used for normalisation.
    private var rawCounts: [String: Int] {
        var result: [String: Int] = [:]
        for user in contacts {
            let chats = (user.chats?.allObjects as? [Chat]) ?? []
            let count = chats.map { $0.messages?.count ?? 0 }.max() ?? 0
            result[user.id] = count
        }
        return result
    }

    private var metricsMap: [String: ContactMetrics] {
        let counts = rawCounts
        let maxCount = counts.values.max() ?? 0
        let now = Date()
        var map: [String: ContactMetrics] = [:]
        for user in contacts {
            let count = counts[user.id] ?? 0
            let score: CGFloat = maxCount > 0 ? CGFloat(count) / CGFloat(maxCount) : 0
            let lastMsg = ((user.chats?.allObjects as? [Chat]) ?? [])
                .compactMap { $0.lastMessageTime }
                .max()
            let recency: ContactMetrics.Recency
            if let t = lastMsg {
                let age = now.timeIntervalSince(t)
                recency = age < 86_400 ? .fresh : age < 604_800 ? .recent : .none
            } else {
                recency = .none
            }
            map[user.id] = ContactMetrics(frequencyScore: score, recency: recency)
        }
        return map
    }

    var body: some View {
        GeometryReader { geo in
            let engine  = HoneycombLayoutEngine(contacts: contacts, canvasSize: geo.size)
            let metrics = metricsMap

            // Canvas is screen-sized; contacts that overflow (large grids when
            // zoomed to 1:1) are clipped by ZoomableCloud and visible when zoomed out.
            ZStack(alignment: .topLeading) {
                Color.clear.frame(width: geo.size.width, height: geo.size.height)

                ForEach(engine.items) { item in
                    ContactCircle(
                        user:         item.user,
                        cellSize:     engine.cellSize,
                        metrics:      metrics[item.user.id] ?? .zero,
                        canvasPos:    item.position,
                        canvasScale:  canvasScale,
                        canvasOffset: canvasOffset,
                        screenSize:   screenSize
                    ) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) {
                            selected = item.user
                        }
                    }
                    .position(item.position)
                }
            }
        }
    }
}

// MARK: - Contact Circle

private struct ContactCircle: View {
    @ObservedObject var user: User
    /// Base cell size from the layout engine (cellWidth × 0.74).
    let cellSize:     CGFloat
    let metrics:      ContactMetrics
    let canvasPos:    CGPoint
    let canvasScale:  CGFloat
    let canvasOffset: CGSize
    let screenSize:   CGSize
    var onTap: () -> Void

    @State private var touchMoved = false

    // MARK: Size
    //
    // Frequency score drives rendered diameter in the range [0.55 … 0.75] × cellWidth.
    // Upper bound kept well below the hex vertical step (cellWidth × 0.866) so that
    // even with the proximity scale boost circles never visually overlap.
    private var effectiveSize: CGFloat {
        let f = 0.55 + 0.20 * metrics.frequencyScore  // [0.55 … 0.75]
        return cellSize / 0.74 * f                     // remap: cellSize = cellWidth×0.74
    }

    var body: some View {
        ZStack {
            if let data = user.avatarData, let img = PlatformImage(data: data) {
                Image(platformImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                HexagonShape().fill(accentColor.opacity(0.18))
                Text(initials)
                    .font(CTFont.bold(effectiveSize * 0.26))
                    .foregroundStyle(accentColor)
            }
        }
        .frame(width: effectiveSize, height: effectiveSize)
        .clipShape(HexagonShape())
        .overlay(HexagonShape().stroke(borderColor, lineWidth: 1.5))
        .scaleEffect(proximityScale)
        .opacity(proximityOpacity)
        // Use DragGesture(minimumDistance: 0) so we can distinguish a stationary
        // tap from a drag that happens to end over the contact. Only fire onTap
        // when the finger hasn't moved more than 8 pt — matching the parent
        // canvas drag threshold — so pan/zoom never triggers navigation.
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    if hypot(value.translation.width, value.translation.height) > 8 {
                        touchMoved = true
                    }
                }
                .onEnded { value in
                    defer { touchMoved = false }
                    guard !touchMoved else { return }
                    guard hypot(value.translation.width, value.translation.height) <= 8 else { return }
                    onTap()
                }
        )
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
        return 1.0 + 0.10 * t  // max ×1.10 — keeps circles within their hex cells
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
        user.isBlocked ? Color.red.opacity(0.55) : Color.CT.textDim.opacity(0.5)
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
        ("u1",  "alice",   "Alice Wonderland"),
        ("u2",  "bob",     "Bob Builder"),
        ("u3",  "charlie", "Charlie Chaplin"),
        ("u4",  "dave",    "Dave Villain"),
        ("u5",  "eva",     "Eva Elfie"),
        ("u6",  "frank",   "Frank Ocean"),
        ("u7",  "grace",   "Grace Hopper"),
        ("u8",  "henry",   "Henry Ford"),
        ("u9",  "iris",    "Iris Chang"),
        ("u10", "james",   "James Webb"),
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
        .preferredColorScheme(.dark)
}

#Preview("Empty") {
    let container = PreviewHelpers.createPreviewContainer()
    let context = container.viewContext
    let chatsVM = ChatsViewModel()
    chatsVM.setContext(context)
    return SynapsView()
        .environment(\.managedObjectContext, context)
        .environment(chatsVM)
        .preferredColorScheme(.dark)
}
