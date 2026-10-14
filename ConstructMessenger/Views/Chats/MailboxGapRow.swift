//
//  MailboxGapRow.swift
//  Construct Messenger
//
//  "Messages from … to … may not have arrived" — once, above the chat list, until closed
//  (`MailboxGapNotice`, decisions/mailbox-gap-is-reported.md). iOS and Desktop.
//

import SwiftUI

struct MailboxGapRow: View {
    let interval: MailboxGapNotice.Interval
    let onDismiss: () -> Void

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private var body_: String {
        let from = Self.formatter.string(from: interval.from)
        guard let until = interval.until else {
            return String(format: NSLocalizedString("mailbox_gap_body_open", comment: ""), from)
        }
        return String(format: NSLocalizedString("mailbox_gap_body", comment: ""), from, Self.formatter.string(from: until))
    }

    var body: some View {
        HStack(alignment: .top, spacing: CTLayout.inlinePad) {
            Image(systemName: "exclamationmark.bubble")
                .font(CTFont.headline)
                .foregroundStyle(Color.CT.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: CTLayout.inlinePad / 2) {
                Text(NSLocalizedString("mailbox_gap_title", comment: ""))
                    .font(CTFont.bodyEmphasis)
                    .foregroundColor(Color.CT.text)
                Text(body_)
                    .font(CTFont.secondary)
                    .foregroundColor(Color.CT.textDim)
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(CTFont.secondary)
                    .foregroundStyle(Color.CT.textDim)
                    .frame(width: CTLayout.hitTarget, height: CTLayout.hitTarget)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(NSLocalizedString("close", comment: ""))
        }
        .padding(CTLayout.edgePad)
        .background(Color.CT.bgMsg)
        .clipShape(CTShape.card())
    }
}
