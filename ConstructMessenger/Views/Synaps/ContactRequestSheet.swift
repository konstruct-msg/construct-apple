import SwiftUI

/// Sheet for an incoming contact request — confirm / decline+block / report spam.
/// CT chrome with SF Symbols (no ASCII action tokens).
struct ContactRequestSheet: View {

    let request: ContactRequestsViewModel.IncomingRequest
    @Environment(\.dismiss) private var dismiss
    @State private var isProcessing = false
    @State private var activeAction: ActionKind?
    @State private var errorMessage: String?

    var onAccept: () async throws -> Void
    var onDeclineBlock: () async throws -> Void
    var onSpamBlock: () async throws -> Void

    private enum ActionKind {
        case accept, decline, spam
    }

    private var displayTitle: String {
        if let name = request.displayName, !name.isEmpty { return name }
        if let username = request.username, !username.isEmpty { return "@\(username)" }
        return DisplayNameGenerator.generate(from: request.fromUserId)
    }

    private var subtitleHandle: String? {
        if let username = request.username, !username.isEmpty { return "@\(username)" }
        return nil
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
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(Color.CT.accent)
                }
                .buttonStyle(.plain)
                .disabled(isProcessing)
            }

            Rectangle()
                .fill(Color.CT.noise)
                .frame(height: 1)

            ScrollView {
                VStack(spacing: 20) {
                    // Identity header
                    VStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.CT.bgMsg)
                                .frame(width: 72, height: 72)
                            IdenticonView(seed: request.fromUserId)
                                .frame(width: 56, height: 56)
                                .clipShape(Circle())
                        }
                        .overlay(
                            Circle()
                                .stroke(Color.CT.noise, lineWidth: 1)
                                .frame(width: 72, height: 72)
                        )

                        VStack(spacing: 4) {
                            Text(displayTitle)
                                .font(CTFont.bold(17))
                                .foregroundColor(Color.CT.text)
                                .multilineTextAlignment(.center)

                            if let subtitleHandle, subtitleHandle != displayTitle {
                                Text(subtitleHandle)
                                    .font(CTFont.regular(13))
                                    .foregroundColor(Color.CT.textDim)
                            }

                            Text(NSLocalizedString("contact_request_from_title", comment: ""))
                                .font(CTFont.regular(13))
                                .foregroundColor(Color.CT.textDim)
                                .multilineTextAlignment(.center)
                                .padding(.top, 2)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(CTFont.regular(12))
                            .foregroundColor(Color.CT.danger)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }

                    VStack(spacing: 10) {
                        // Primary: accept
                        primaryButton(
                            title: NSLocalizedString("contact_request_confirm", comment: ""),
                            systemImage: "checkmark.circle.fill",
                            kind: .accept,
                            role: .primary
                        ) {
                            await perform(.accept) { try await onAccept() }
                        }

                        // Secondary: decline + block
                        primaryButton(
                            title: NSLocalizedString("contact_request_decline_block", comment: ""),
                            systemImage: "hand.raised.fill",
                            kind: .decline,
                            role: .destructive
                        ) {
                            await perform(.decline) { try await onDeclineBlock() }
                        }

                        // Tertiary: spam
                        Button {
                            Task { await perform(.spam) { try await onSpamBlock() } }
                        } label: {
                            HStack(spacing: 6) {
                                if isProcessing && activeAction == .spam {
                                    ProgressView()
                                        .tint(Color.CT.danger)
                                        .scaleEffect(0.8)
                                } else {
                                    Image(systemName: "exclamationmark.bubble")
                                        .font(.system(size: 13, weight: .semibold))
                                }
                                Text(NSLocalizedString("contact_request_spam_block", comment: ""))
                                    .font(CTFont.regular(13))
                            }
                            .foregroundColor(isProcessing ? Color.CT.textDim : Color.CT.danger.opacity(0.9))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                        .disabled(isProcessing)
                    }
                    .padding(.top, 8)

                    Spacer(minLength: 12)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .ctBackground()
    }

    private enum ButtonRole {
        case primary, destructive
    }

    @ViewBuilder
    private func primaryButton(
        title: String,
        systemImage: String,
        kind: ActionKind,
        role: ButtonRole,
        action: @escaping () async -> Void
    ) -> some View {
        let busy = isProcessing && activeAction == kind
        let dimmed = isProcessing && activeAction != kind

        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 8) {
                if busy {
                    ProgressView()
                        .tint(role == .primary ? Color.CT.bg : Color.CT.danger)
                        .scaleEffect(0.85)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(title)
                    .font(CTFont.medium(14))
            }
            .foregroundColor(foreground(for: role, dimmed: dimmed))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(background(for: role, dimmed: dimmed))
            .clipShape(CTShape.control())
            .overlay(
                CTShape.control()
                    .stroke(border(for: role, dimmed: dimmed), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isProcessing)
    }

    private func foreground(for role: ButtonRole, dimmed: Bool) -> Color {
        if dimmed { return Color.CT.textDim }
        switch role {
        case .primary: return Color.CT.bg
        case .destructive: return Color.CT.danger
        }
    }

    private func background(for role: ButtonRole, dimmed: Bool) -> Color {
        if dimmed { return Color.CT.bgMsg.opacity(0.6) }
        switch role {
        case .primary: return Color.CT.accent
        case .destructive: return Color.CT.bgMsg
        }
    }

    private func border(for role: ButtonRole, dimmed: Bool) -> Color {
        if dimmed { return Color.CT.noise }
        switch role {
        case .primary: return Color.clear
        case .destructive: return Color.CT.danger.opacity(0.35)
        }
    }

    private func perform(_ kind: ActionKind, _ action: @escaping () async throws -> Void) async {
        isProcessing = true
        activeAction = kind
        errorMessage = nil
        do {
            try await action()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isProcessing = false
        activeAction = nil
    }
}
