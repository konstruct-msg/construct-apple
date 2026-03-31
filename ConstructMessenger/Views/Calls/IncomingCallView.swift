//
//  IncomingCallView.swift
//  Construct Messenger
//
//  In-app incoming call overlay — shown when app is in foreground.
//  CallKit system UI handles the lock-screen / background case.
//

import SwiftUI

#if os(iOS)
struct IncomingCallView: View {
    let session: CallManager.CallSession

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 20) {
                // Header pill
                Capsule()
                    .fill(Color.Construct.dim)
                    .frame(width: 36, height: 4)
                    .padding(.top, 10)

                // Avatar + caller info
                VStack(spacing: 12) {
                    HexagonAvatarView(
                        userId: session.peerUserId,
                        displayName: session.peerName,
                        size: 72
                    )

                    Text(session.peerName)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.Construct.textBright)

                    Text(NSLocalizedString("call_incoming_audio", comment: ""))
                        .font(.subheadline)
                        .foregroundStyle(Color.Construct.textDim)
                }

                // Answer / Decline row
                HStack(spacing: 52) {
                    // Decline
                    VStack(spacing: 6) {
                        Button {
                            CallManager.shared.declineIncomingCall()
                        } label: {
                            Image(systemName: "phone.down.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(.white)
                                .frame(width: 64, height: 64)
                                .background(Color.red)
                                .clipShape(Circle())
                        }
                        Text(NSLocalizedString("call_decline", comment: ""))
                            .font(.caption2)
                            .foregroundStyle(Color.Construct.textDim)
                    }

                    // Answer
                    VStack(spacing: 6) {
                        Button {
                            CallManager.shared.answerIncomingCall()
                        } label: {
                            Image(systemName: "phone.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(.white)
                                .frame(width: 64, height: 64)
                                .background(Color.Construct.green)
                                .clipShape(Circle())
                        }
                        Text(NSLocalizedString("call_answer", comment: ""))
                            .font(.caption2)
                            .foregroundStyle(Color.Construct.textDim)
                    }
                }
                .padding(.bottom, 32)
            }
            .frame(maxWidth: .infinity)
            .background(Color.Construct.bg2)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .ignoresSafeArea(edges: .bottom)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

#Preview {
    ZStack {
        Color.Construct.bg.ignoresSafeArea()
        IncomingCallView(session: .init(
            id: UUID().uuidString,
            uuid: UUID(),
            peerUserId: "user1",
            peerName: "鈴木 けんじ",
            direction: .incoming
        ))
    }
}
#endif
