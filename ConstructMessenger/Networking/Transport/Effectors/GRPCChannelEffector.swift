//
//  GRPCChannelEffector.swift
//  Construct Messenger
//
//  Concrete `ChannelEffector` that adapts the FSM to the existing GRPCChannelManager.
//

import Foundation

struct GRPCChannelEffector: ChannelEffector {
    func invalidateClient() async {
        if VeilProxyStore.loadMode().allowsDirectPath {
            GRPCChannelManager.shared.invalidatePersistentClient()
        } else {
            GRPCChannelManager.shared.dropDirectPath()
        }
    }

    func setVeilPort(_ port: UInt16?) async {
        GRPCChannelManager.shared.setDirectProxyPort(port)
    }
}
