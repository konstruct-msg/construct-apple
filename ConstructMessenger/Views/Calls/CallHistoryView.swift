//
//  CallHistoryView.swift
//  Construct Messenger
//
//  Recent calls screen — Construct Terminal design.
//

import SwiftUI
import CoreData

#if os(iOS)
struct CallHistoryView: View {
    @Environment(\.managedObjectContext) private var viewContext

    // iOS 26: @FetchRequest(keyPath:) calls entity(). Using a plain @State array +
    // manual NSFetchRequest(entityName:) avoids the class-introspection path entirely.
    @State private var records: [CTCallRecord] = []
    @State private var selectedFilter: CallHistoryFilter = .all
    @State private var showClearConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(NSLocalizedString("calls_recents", comment: "").uppercased())
                    .font(CTFont.bold(14))
                    .foregroundColor(Color.CT.text)
                    .tracking(4)
                Spacer()
                if !records.isEmpty {
                    Button(action: { showClearConfirm = true }) {
                        Text("[\(NSLocalizedString("calls_clear", comment: ""))]")
                            .font(CTFont.bold(13))
                            .foregroundColor(Color.CT.danger)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, CTLayout.edgePad)
            .frame(height: CTLayout.navBarHeight)

            filterBar

            ZStack {
                CTMatrixBackground().ignoresSafeArea()

                if filteredRecords.isEmpty {
                    emptyState
                } else {
                    callList
                }
            }
        }
        .background(Color.CT.bg.ignoresSafeArea())
        .onAppear { loadRecords() }
        .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave)) { note in
            guard notificationContainsCallRecordChanges(note) else { return }
            loadRecords()
        }
        .alert(NSLocalizedString("calls_clear_confirm", comment: ""), isPresented: $showClearConfirm) {
            Button(NSLocalizedString("calls_clear", comment: ""), role: .destructive) {
                CallHistoryService.shared.deleteAll()
            }
            Button(NSLocalizedString("cancel", comment: ""), role: .cancel) {}
        }
    }

    private var filterBar: some View {
        HStack {
            CTModeSelector(
                selection: $selectedFilter,
                options: CallHistoryFilter.allCases,
                labels: [
                    .all: NSLocalizedString("calls_filter_all", comment: ""),
                    .missed: NSLocalizedString("calls_filter_missed", comment: "")
                ],
                width: .infinity
            )
            Spacer()
        }
        .padding(.horizontal, CTLayout.edgePad)
        .padding(.bottom, 10)
    }

    private var filteredRecords: [CTCallRecord] {
        switch selectedFilter {
        case .all:
            return records
        case .missed:
            return records.filter { $0.status == .missed }
        }
    }

    private var groupedSections: [CallHistorySection] {
        let grouped = Dictionary(grouping: filteredRecords, by: sectionKind(for:))
        return CallHistorySection.Kind.allCases.compactMap { kind in
            guard let records = grouped[kind], !records.isEmpty else { return nil }
            return CallHistorySection(kind: kind, records: records)
        }
    }

    private func loadRecords() {
        let req = NSFetchRequest<NSManagedObject>(entityName: "CallRecord")
        req.sortDescriptors = [NSSortDescriptor(key: "startedAt", ascending: false)]
        req.fetchLimit = 200
        let objects = (try? viewContext.fetch(req)) ?? []
        records = objects.compactMap { $0 as? CTCallRecord }
    }

    private func notificationContainsCallRecordChanges(_ note: Notification) -> Bool {
        let keys = [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey]
        for key in keys {
            guard let objects = note.userInfo?[key] as? Set<NSManagedObject> else { continue }
            if objects.contains(where: { $0.entity.name == "CallRecord" }) {
                return true
            }
        }
        return false
    }

    private var callList: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(groupedSections) { section in
                    Section {
                        ForEach(section.records, id: \.id) { record in
                            CallHistoryRow(
                                record: record,
                                onDelete: { deleteRecord(record) },
                                onCallBack: { callBack(record) }
                            )
                            Rectangle()
                                .fill(Color.CT.noise.opacity(0.35))
                                .frame(height: 1)
                                .padding(.leading, 72)
                        }
                    } header: {
                        sectionHeader(title: section.title)
                    }
                }
                Color.clear.frame(height: 72)
            }
        }
    }

    private func sectionHeader(title: String) -> some View {
        ZStack {
            Color.CT.bg.opacity(0.96)
            HStack {
                Text(title.uppercased())
                    .font(CTFont.bold(11))
                    .foregroundStyle(Color.CT.accentDim)
                Spacer()
            }
            .padding(.horizontal, CTLayout.edgePad)
            .padding(.vertical, 8)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text(emptyStateText)
                .font(CTFont.regular(13))
                .foregroundStyle(Color.CT.textDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateText: String {
        switch selectedFilter {
        case .all:
            return NSLocalizedString("calls_empty", comment: "")
        case .missed:
            return NSLocalizedString("calls_empty_missed", comment: "")
        }
    }

    private func deleteRecord(_ record: CTCallRecord) {
        viewContext.delete(record)
        try? viewContext.save()
    }

    private func callBack(_ record: CTCallRecord) {
        guard CallsFeature.isEnabled else { return }
        Task {
            await CallManager.shared.startOutgoingCall(
                to: record.peerUserId,
                displayName: record.peerName,
                hasVideo: false
            )
        }
    }

    private func sectionKind(for record: CTCallRecord) -> CallHistorySection.Kind {
        guard let startedAt = record.startedAt else { return .older }
        let calendar = Calendar.current
        if calendar.isDateInToday(startedAt) {
            return .today
        }
        if calendar.isDateInYesterday(startedAt) {
            return .yesterday
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()), startedAt >= weekAgo {
            return .earlier
        }
        return .older
    }
}

private enum CallHistoryFilter: CaseIterable {
    case all
    case missed
}

private struct CallHistorySection: Identifiable {
    enum Kind: CaseIterable {
        case today
        case yesterday
        case earlier
        case older
    }

    let kind: Kind
    let records: [CTCallRecord]

    var id: Kind { kind }

    var title: String {
        switch kind {
        case .today:
            return NSLocalizedString("calls_section_today", comment: "")
        case .yesterday:
            return NSLocalizedString("calls_section_yesterday", comment: "")
        case .earlier:
            return NSLocalizedString("calls_section_earlier", comment: "")
        case .older:
            return NSLocalizedString("calls_section_older", comment: "")
        }
    }
}

private struct CallHistoryRow: View {
    let record: CTCallRecord
    var onDelete: () -> Void
    var onCallBack: () -> Void

    var body: some View {
        Button(action: onCallBack) {
            HStack(spacing: 12) {
                Text(directionTag)
                    .font(CTFont.regular(10))
                    .foregroundStyle(directionColor)
                    .frame(width: 20, alignment: .center)

                MainAvatarView(
                    userId: record.peerUserId,
                    displayName: record.peerName,
                    size: 40
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(record.peerName)
                        .font(CTFont.bold(15))
                        .foregroundStyle(record.status == .missed ? Color.CT.danger : Color.CT.text)

                    Text(statusLabel)
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.textDim)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text(relativeTime)
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.textDim)

                    if let dur = record.formattedDuration {
                        Text(dur)
                            .font(CTFont.regular(10))
                            .foregroundStyle(Color.CT.textDim)
                    }
                }

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.CT.accent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: onDelete) {
                Text(NSLocalizedString("delete", comment: ""))
            }
            Button(action: onCallBack) {
                Text(NSLocalizedString("call_call_back", comment: ""))
            }
            .tint(Color.CT.accent)
        }
    }

    private var directionTag: String {
        switch record.direction {
        case .outgoing:
            return "↗"
        case .incoming:
            return "↙"
        @unknown default:
            return "~"
        }
    }

    private var directionColor: Color {
        switch record.status {
        case .missed, .declined:
            return Color.CT.danger
        case .completed:
            return record.direction == .outgoing ? Color.CT.textDim : Color.CT.accent
        case .failed:
            return .orange
        @unknown default:
            return Color.CT.textDim
        }
    }

    private var statusLabel: String {
        switch record.status {
        case .completed:
            return record.direction == .outgoing
                ? NSLocalizedString("call_outgoing", comment: "")
                : NSLocalizedString("call_incoming", comment: "")
        case .missed:
            return NSLocalizedString("call_missed", comment: "")
        case .declined:
            return NSLocalizedString("call_declined", comment: "")
        case .failed:
            return NSLocalizedString("call_failed", comment: "")
        @unknown default:
            return ""
        }
    }

    private var relativeTime: String {
        guard let date = record.startedAt else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

#Preview {
    let container = PreviewHelpers.createPreviewContainer()
    return CallHistoryView()
        .environment(\.managedObjectContext, container.viewContext)
        .preferredColorScheme(.dark)
}
#endif
