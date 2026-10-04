//
//  RecoveryReminderRow.swift
//  Construct Messenger
//
//  The chat list's one line about the recovery key, once the copy is overdue or the phrase is
//  gone (`RecoveryReminder`). Closable: it comes back after the same delay, which is the
//  "escalating, not a wall" of `decisions/recovery-key-backup-is-deferred-not-skipped.md` §3.
//

import SwiftUI

struct RecoveryReminderRow: View {
    let reminder: RecoveryReminder
    /// Opens the copy. Not offered when the phrase is lost — there is nothing left to copy.
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: CTLayout.inlinePad) {
            Image(systemName: reminder == .phraseLost ? "exclamationmark.triangle.fill" : "key.fill")
                .font(CTFont.headline)
                .foregroundStyle(reminder == .phraseLost ? Color.CT.danger : Color.CT.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: CTLayout.inlinePad / 2) {
                Text(NSLocalizedString(
                    reminder == .phraseLost ? "recovery_reminder_lost_title" : "recovery_backup_pending_title",
                    comment: ""
                ))
                .font(CTFont.bodyEmphasis)
                .foregroundColor(Color.CT.text)
                Text(NSLocalizedString(
                    reminder == .phraseLost ? "recovery_reminder_lost_body" : "recovery_backup_pending_subtitle",
                    comment: ""
                ))
                .font(CTFont.secondary)
                .foregroundColor(Color.CT.textDim)
                .fixedSize(horizontal: false, vertical: true)
                if reminder == .backupDue {
                    Button(action: onOpen) {
                        Text(NSLocalizedString("recovery_backup_show", comment: ""))
                            .font(CTFont.bodyEmphasis)
                    }
                    .buttonStyle(.borderless)
                    .tint(Color.CT.accent)
                }
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
