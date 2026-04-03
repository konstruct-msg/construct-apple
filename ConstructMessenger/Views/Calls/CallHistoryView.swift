//
//  CallHistoryView.swift
//  Construct Messenger
//
//  Recent calls screen — iOS Phone app "Recents" aesthetic
//  within the Construct visual language.
//

import SwiftUI
import CoreData

#if os(iOS)
struct CallHistoryView: View {
    @Environment(\.managedObjectContext) private var viewContext

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(key: "startedAt", ascending: false)],
        animation: .default
    )
    private var records: FetchedResults<CallRecord>

    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            Group {
                if records.isEmpty {
                    emptyState
                } else {
                    callList
                }
            }
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(NSLocalizedString("calls_recents", comment: ""))
                        .font(CTFont.bold(13))
                        .foregroundStyle(Color.CT.text)
                        .tracking(3)
                }
                
                if !records.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(NSLocalizedString("calls_clear", comment: "")) {
                            showClearConfirm = true
                        }
                        .foregroundStyle(Color.CT.accent)
                    }
                }
            }
            .confirmationDialog(
                NSLocalizedString("calls_clear_confirm", comment: ""),
                isPresented: $showClearConfirm,
                titleVisibility: .visible
            ) {
                Button(NSLocalizedString("calls_clear", comment: ""), role: .destructive) {
                    CallHistoryService.shared.deleteAll()
                }
            }
        }
        .background(Color.CT.bg)
    }

    // MARK: - List

    private var callList: some View {
        List {
            ForEach(records, id: \.id) { record in
                CallHistoryRow(record: record)
                    .listRowBackground(Color.CT.bg)
                    .listRowSeparatorTint(Color.CT.noise)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            deleteRecord(record)
                        } label: {
                            Label("delete", systemImage: "trash")
                        }

                        Button {
                            callBack(record)
                        } label: {
                            Label(NSLocalizedString("call_call_back", comment: ""), systemImage: "phone.fill")
                        }
                        .tint(Color.CT.accent)
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.CT.bg)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "phone.slash")
                .font(.system(size: 44))
                .foregroundStyle(Color.CT.textDim)
            Text(NSLocalizedString("calls_empty", comment: ""))
                .font(.subheadline)
                .foregroundStyle(Color.CT.textDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func deleteRecord(_ record: CallRecord) {
        viewContext.delete(record)
        try? viewContext.save()
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
}

// MARK: - Row

private struct CallHistoryRow: View {
    let record: CallRecord

    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            CallAvatarView(userId: record.peerUserId, displayName: record.peerName, size: 44)

            // Name + direction/status
            VStack(alignment: .leading, spacing: 3) {
                Text(record.peerName)
                    .font(.body)
                    .foregroundStyle(record.status == .missed ? Color.red : Color.CT.text)

                HStack(spacing: 4) {
                    Image(systemName: directionIcon)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(directionColor)
                    Text(statusLabel)
                        .font(.caption)
                        .foregroundStyle(Color.CT.textDim)
                }
            }

            Spacer()

            // Time + duration
            VStack(alignment: .trailing, spacing: 3) {
                Text(relativeTime)
                    .font(CTFont.regular(12))
                    .foregroundStyle(Color.CT.textDim)

                if let dur = record.formattedDuration {
                    Text(dur)
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.textDim)
                }
            }

            // Call-back phone icon
            Image(systemName: "phone.fill")
                .font(.system(size: 16))
                .foregroundStyle(Color.CT.accent)
        }
        .padding(.vertical, 4)
    }

    private var directionIcon: String {
        switch record.direction {
        case .outgoing: return "arrow.up.right"
        case .incoming: return record.status == .missed ? "arrow.down.left" : "arrow.down.left"
        @unknown default: return "arrow.left.and.right"
        }
    }

    private var directionColor: Color {
        switch record.status {
        case .missed, .declined: return .red
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
}
#endif
