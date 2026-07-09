import SwiftUI

/// Sheet presented when a user taps an incoming contact request row.
/// Offers 3 options: Confirm / Decline+Block / Report Spam+Block.
struct ContactRequestSheet: View {

    let request: ContactRequestsViewModel.IncomingRequest
    @Environment(\.dismiss) private var dismiss
    @State private var isProcessing = false
    @State private var errorMessage: String?

    var onAccept: () async throws -> Void
    var onDeclineBlock: () async throws -> Void
    var onSpamBlock: () async throws -> Void

    private var displayTitle: String {
        if let name = request.displayName, !name.isEmpty { return name }
        if let username = request.username, !username.isEmpty { return "@\(username)" }
        return DisplayNameGenerator.generate(from: request.fromUserId)
    }

    var body: some View {
        VStack(spacing: 0) {
            CTNavBar(
                title: NSLocalizedString("contact_request_sheet_title", comment: ""),
                showBack: false
            ) {
                EmptyView()
            } trailing: {
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 18))
                        .foregroundColor(Color.CT.accent)
                }
                .buttonStyle(.plain)
            }

            Rectangle()
                .fill(Color.CT.noise)
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(displayTitle)
                        .font(CTFont.bold(16))
                        .foregroundColor(Color.CT.text)

                    Text(NSLocalizedString("contact_request_from_title", comment: ""))
                        .font(CTFont.regular(13))
                        .foregroundColor(Color.CT.textDim)
                }
                .padding(.top, 24)

                if let errorMessage {
                    Text(errorMessage)
                        .font(CTFont.regular(12))
                        .foregroundColor(Color.CT.danger)
                }

                Rectangle()
                    .fill(Color.CT.noise)
                    .frame(height: 1)

                actionButton(
                    label: NSLocalizedString("contact_request_confirm", comment: ""),
                    color: Color.CT.accent,
                    disabled: isProcessing
                ) {
                    await perform { try await onAccept() }
                }

                Rectangle()
                    .fill(Color.CT.noise)
                    .frame(height: 1)

                actionButton(
                    label: NSLocalizedString("contact_request_decline_block", comment: ""),
                    color: Color.CT.danger,
                    disabled: isProcessing
                ) {
                    await perform { try await onDeclineBlock() }
                }

                actionButton(
                    label: NSLocalizedString("contact_request_spam_block", comment: ""),
                    color: Color.CT.danger,
                    disabled: isProcessing
                ) {
                    await perform { try await onSpamBlock() }
                }

                Spacer()
            }
            .padding(.horizontal, 20)
        }
        .ctBackground()
    }

    @ViewBuilder
    private func actionButton(
        label: String,
        color: Color,
        disabled: Bool,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack {
                Text(label)
                    .font(CTFont.regular(14))
                    .foregroundColor(disabled ? Color.CT.textDim : color)
                Spacer()
                if isProcessing {
                    ProgressView()
                        .tint(Color.CT.textDim)
                        .scaleEffect(0.8)
                }
            }
            .padding(.vertical, 12)
        }
        .disabled(disabled)
    }

    private func perform(_ action: @escaping () async throws -> Void) async {
        isProcessing = true
        errorMessage = nil
        do {
            try await action()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isProcessing = false
    }
}
