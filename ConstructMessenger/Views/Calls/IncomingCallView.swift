//
//  IncomingCallView.swift
//  Construct Messenger
//
//  In-app incoming call overlay — shown when app is in foreground.
//  CallKit system UI handles the lock-screen / background case.
//

import SwiftUI

struct IncomingCallView: View {
    let session: CallManager.CallSession

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 20) {
                // Header drag indicator
                Rectangle()
                    .fill(Color.CT.noise)
                    .frame(width: 36, height: 4)
                    .padding(.top, 10)

                // Avatar + caller info
                VStack(spacing: 12) {
                    CallAvatarView(userId: session.peerUserId, displayName: session.peerName, size: 72)

                    Text(session.peerName)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.CT.text)

                    Text(NSLocalizedString("call_incoming_audio", comment: ""))
                        .font(.subheadline)
                        .foregroundStyle(Color.CT.textDim)
                }

                // Answer / Decline row
                HStack(spacing: 52) {
                    // Decline
                    VStack(spacing: 6) {
                        Button {
                            CallManager.shared.declineIncomingCall()
                        } label: {
                            Image(systemName: "phone.down.fill")
                                .font(.system(size: CTLayout.callIconSize, weight: .medium))
                                .foregroundStyle(.white)
                                .frame(width: 64, height: 64)
                                .background(Color.CT.danger)
                                .clipShape(Circle())
                        }
                        Text(NSLocalizedString("call_decline", comment: ""))
                            .font(CTFont.regular(10))
                            .foregroundStyle(Color.CT.textDim)
                    }

                    // Answer
                    VStack(spacing: 6) {
                        Button {
                            CallManager.shared.answerIncomingCall()
                        } label: {
                            Image(systemName: "phone.fill")
                                .font(.system(size: CTLayout.callIconSize, weight: .medium))
                                .foregroundStyle(.white)
                                .frame(width: 64, height: 64)
                                .background(Color.CT.accent)
                                .clipShape(Circle())
                        }
                        Text(NSLocalizedString("call_answer", comment: ""))
                            .font(CTFont.regular(10))
                            .foregroundStyle(Color.CT.textDim)
                    }
                }
                .padding(.bottom, 32)
            }
            .frame(maxWidth: .infinity)
            .background(Color.CT.bgMsg)
            .overlay(Rectangle().strokeBorder(Color.CT.noise, lineWidth: 1))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .ignoresSafeArea(edges: .bottom)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

#Preview {
    ZStack {
        Color.CT.bg.ignoresSafeArea()
        IncomingCallView(session: .init(
            id: UUID().uuidString,
            uuid: UUID(),
            peerUserId: "user1",
            peerName: "鈴木 けんじ",
            direction: .incoming
        ))
    }
}
