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
    // initialisation, which triggers the "unique match" CoreData crash on iOS 26 when
    // the NSManagedObjectModel is not yet fully settled. Using a plain @State array +
    // manual NSFetchRequest(entityName:) avoids the class-introspection path entirely.
    @State private var records: [CTCallRecord] = []
    @State private var showClearConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            CTNavBar(
                title: NSLocalizedString("calls_recents", comment: ""),
                trailingSymbol: records.isEmpty ? nil : "[\(NSLocalizedString("calls_clear", comment: ""))]",
                trailingColor: Color.CT.danger,
                trailingAction: { showClearConfirm = true }
            )

            ZStack {
                CTMatrixBackground().ignoresSafeArea()

                if records.isEmpty {
                    emptyState
                } else {
                    callList
                }
            }
        }
        .background(Color.CT.bg.ignoresSafeArea())
        .onAppear { loadRecords() }
        // Refresh whenever any CoreData save happens (new call logged, record deleted, clear all)
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

    // MARK: - Data

    private func loadRecords() {
        // Fetch as NSManagedObject to avoid Swift bridging casting pitfalls on iOS 26.
        let req = NSFetchRequest<NSManagedObject>(entityName: "CallRecord")
        req.sortDescriptors = [NSSortDescriptor(key: "startedAt", ascending: false)]
        req.fetchLimit = 200
        let objects = (try? viewContext.fetch(req)) ?? []
        records = objects.compactMap { $0 as? CTCallRecord }
    }

    /// Ignore unrelated Core Data saves from other screens/tabs.
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

    // MARK: - List

    private var callList: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(records, id: \.id) { record in
                    CallHistoryRow(record: record, onDelete: { deleteRecord(record) }, onCallBack: { callBack(record) })
                    Rectangle()
                        .fill(Color.CT.noise.opacity(0.35))
                        .frame(height: 1)
                        .padding(.leading, 72)
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("[ no calls ]")
                .font(CTFont.regular(20))
                .foregroundStyle(Color.CT.textDim)
            Text(NSLocalizedString("calls_empty", comment: ""))
                .font(CTFont.regular(13))
                .foregroundStyle(Color.CT.textDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func deleteRecord(_ record: CTCallRecord) {
        viewContext.delete(record)
        try? viewContext.save()
        // loadRecords() will be called automatically via NSManagedObjectContextDidSave
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
}

// MARK: - Row

private struct CallHistoryRow: View {
    let record: CTCallRecord
    var onDelete: () -> Void
    var onCallBack: () -> Void

    var body: some View {
        Button(action: onCallBack) {
            HStack(spacing: 12) {
                // Direction indicator
                Text(directionTag)
                    .font(CTFont.regular(10))
                    .foregroundStyle(directionColor)
                    .frame(width: 20, alignment: .center)

                // Avatar
                MainAvatarView(
                    userId: record.peerUserId,
                    displayName: record.peerName,
                    size: 40
                )

                // Name + status
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.peerName)
                        .font(CTFont.bold(15))
                        .foregroundStyle(record.status == .missed ? Color.CT.danger : Color.CT.text)

                    Text(statusLabel)
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.textDim)
                }

                Spacer()

                // Time + duration + call-back hint
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
        case .outgoing: return "↗"
        case .incoming: return record.status == .missed ? "↙" : "↙"
        @unknown default: return "~"
        }
    }

    private var directionColor: Color {
        switch record.status {
        case .missed, .declined: return Color.CT.danger
        case .completed:         return record.direction == .outgoing ? Color.CT.textDim : Color.CT.accent
        case .failed:            return .orange
        @unknown default:        return Color.CT.textDim
        }
    }

    private var statusLabel: String {
        switch record.status {
        case .completed:
            return record.direction == .outgoing
                ? NSLocalizedString("call_outgoing", comment: "")
                : NSLocalizedString("call_incoming", comment: "")
        case .missed:   return NSLocalizedString("call_missed", comment: "")
        case .declined: return NSLocalizedString("call_declined", comment: "")
        case .failed:   return NSLocalizedString("call_failed", comment: "")
        @unknown default: return ""
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
