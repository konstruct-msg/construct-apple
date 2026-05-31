//
//  GRPCChannelEffector.swift
//  Construct Messenger
//
//  Concrete `ChannelEffector` that adapts the FSM to the existing GRPCChannelManager.
//

import Foundation

struct GRPCChannelEffector: ChannelEffector {
    func invalidateClient() async {
        GRPCChannelManager.shared.invalidatePersistentClient()
    }

    func setVeilPort(_ port: UInt16?) async {
        GRPCChannelManager.shared.setDirectProxyPort(port)
    }
}
