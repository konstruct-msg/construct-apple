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

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(key: "startedAt", ascending: false)],
        animation: .default
    )
    private var records: FetchedResults<CallRecord>

    @State private var showClearConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            CTNavBar(
                title: NSLocalizedString("calls_recents", comment: ""),
                trailingSymbol: records.isEmpty ? nil : "[\(NSLocalizedString("calls_clear", comment: ""))]",
                trailingColor: Color.CT.danger,
                trailingAction: { showClearConfirm = true }
            )
            Rectangle()
                .fill(Color.CT.noise)
                .frame(height: 1)

            if records.isEmpty {
                emptyState
            } else {
                callList
            }
        }
        .background(Color.CT.bg.ignoresSafeArea())
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

    // MARK: - List

    private var callList: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
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
    var onDelete: () -> Void
    var onCallBack: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Direction tag
            Text(directionTag)
                .font(CTFont.regular(10))
                .foregroundStyle(directionColor)
                .frame(width: 20, alignment: .center)

            // Avatar
            HexagonAvatarView(
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

            // Time + duration
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

            // Call-back button
            Button(action: onCallBack) {
                Text("[↗]")
                    .font(CTFont.regular(13))
                    .foregroundStyle(Color.CT.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
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
