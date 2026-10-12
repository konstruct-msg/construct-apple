//
//  CallHistoryView.swift
//  Construct Messenger
//
//  Recent calls screen — Construct Terminal design.
//

import SwiftUI

#if os(iOS)
struct CallHistoryView: View {
    /// The log as last read from the call store, read again on each of its changes.
    @State private var records: [CallRecord] = []
    @State private var selectedFilter: CallHistoryFilter = .all
    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(NSLocalizedString("calls_recents", comment: ""))
                .inlineNavTitle()
                .connectionSubtitle()
                .toolbar {
                    if !records.isEmpty {
                        ToolbarItem(placement: .primaryAction) {
                            Button(role: .destructive) { showClearConfirm = true } label: {
                                Label(NSLocalizedString("calls_clear", comment: ""), systemImage: "trash")
                            }
                            .barItem()
                        }
                    }
                }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
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
        .task {
            // Subscribed before the first read, so a call logged in between is not missed.
            let changes = LocalRepositories.calls.changes()
            loadRecords()
            for await _ in changes { loadRecords() }
        }
        .alert(NSLocalizedString("calls_clear_confirm", comment: ""), isPresented: $showClearConfirm) {
            Button(NSLocalizedString("calls_clear", comment: ""), role: .destructive) {
                CallHistoryService.shared.deleteAll()
            }
            Button(NSLocalizedString("cancel", comment: ""), role: .cancel) {}
        }
    }

    /// All or missed — the system's segmented control, as the Phone app's recents.
    private var filterBar: some View {
        Picker(selection: $selectedFilter) {
            Text(NSLocalizedString("calls_filter_all", comment: "")).tag(CallHistoryFilter.all)
            Text(NSLocalizedString("calls_filter_missed", comment: "")).tag(CallHistoryFilter.missed)
        } label: {
            EmptyView()
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, CTLayout.edgePad)
        .padding(.bottom, CTLayout.inlinePad)
    }

    private var filteredRecords: [CallRecord] {
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

    private static let shownLimit = 200

    private func loadRecords() {
        do {
            records = try LocalRepositories.calls.calls(limit: Self.shownLimit)
        } catch {
            Log.error("Failed to read call history: \(error)", category: "CallHistory")
        }
    }

    /// A List, so the rows' swipe actions work — under the ScrollView this used to be, the
    /// "delete" and "call back" swipes were never offered.
    private var callList: some View {
        List {
            ForEach(groupedSections) { section in
                Section {
                    ForEach(section.records, id: \.id) { record in
                        CallHistoryRow(
                            record: record,
                            onDelete: { deleteRecord(record) },
                            onCallBack: { callBack(record) }
                        )
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparatorTint(Color.CT.noise)
                    }
                } header: {
                    CTSettingsSectionHeader(title: section.title)
                        .listRowInsets(EdgeInsets())
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label {
                Text(emptyStateText)
                    .font(CTFont.headline)
            } icon: {
                Image(systemName: selectedFilter == .missed ? "phone.arrow.down.left" : "phone")
            }
        }
    }

    private var emptyStateText: String {
        switch selectedFilter {
        case .all:
            return NSLocalizedString("calls_empty", comment: "")
        case .missed:
            return NSLocalizedString("calls_empty_missed", comment: "")
        }
    }

    private func deleteRecord(_ record: CallRecord) {
        CallHistoryService.shared.delete(record.id)
    }

    private func callBack(_ record: CallRecord) {
        guard CallsFeature.isEnabled else { return }
        Task {
            await CallManager.shared.startOutgoingCall(
                to: record.peerUserId,
                displayName: record.peerName,
                hasVideo: false
            )
        }
    }

    private func sectionKind(for record: CallRecord) -> CallHistorySection.Kind {
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
    let records: [CallRecord]

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
    let record: CallRecord
    var onDelete: () -> Void
    var onCallBack: () -> Void

    var body: some View {
        Button(action: onCallBack) {
            HStack(spacing: 12) {
                Image(systemName: directionSymbol)
                    .font(CTIcon.font(CTIcon.caption, weight: .semibold))
                    .foregroundStyle(directionColor)
                    .frame(width: 20, alignment: .center)
                    .accessibilityHidden(true)

                ContactMainAvatarView(
                    userId: record.peerUserId,
                    displayName: record.peerName,
                    size: CTAvatarSize.row
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(record.peerName)
                        .font(CTFont.ui(15, weight: .bold))
                        .foregroundStyle(record.status == .missed ? Color.CT.danger : Color.CT.text)

                    Text(statusLabel)
                        .font(CTFont.caption)
                        .foregroundStyle(Color.CT.textDim)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text(relativeTime)
                        .font(CTFont.caption)
                        .foregroundStyle(Color.CT.textDim)

                    if let dur = record.formattedDuration {
                        Text(dur)
                            .font(CTFont.mono(10))
                            .foregroundStyle(Color.CT.textDim)
                    }
                }

                // The row's tap calls back; the symbol says so (it was an arrow that did not).
                Image(systemName: "phone")
                    .font(CTIcon.font(CTIcon.row))
                    .foregroundStyle(Color.CT.accent)
                    .accessibilityLabel(Text(LocalizedStringKey("call_call_back")))
            }
            .padding(.horizontal, CTLayout.sectionGap)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: onDelete) {
                Text(NSLocalizedString("delete", comment: ""))
            }
            // See ChatsListView: an ancestor tint beats `role: .destructive`.
            .tint(Color.CT.danger)
            Button(action: onCallBack) {
                Text(NSLocalizedString("call_call_back", comment: ""))
            }
            .tint(Color.CT.accent)
        }
    }

    private var directionSymbol: String {
        switch record.direction {
        case .outgoing:
            return "phone.arrow.up.right"
        case .incoming:
            return "phone.arrow.down.left"
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
    CallHistoryView()
        .preferredColorScheme(.dark)
}
#endif
