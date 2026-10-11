//
//  ServerEndpoint.swift
//  Konstruct Notifications (also compiled into the app, which writes it)
//
//  The server the app connects to, as `host:port`. The app resolves it (a custom server from
//  Settings, else `GRPC_HOST` from its Info.plist) and stores the result in the Keychain
//  (`KeychainSessionAccounts.serverEndpoint`) whenever it changes, so the notification extension
//  asks the same server. The extension never resolves it itself: it cannot see the app's
//  UserDefaults or Info.plist defaults, and a guess would fetch from the wrong server.
//

import Foundation

struct ServerEndpoint: Equatable {
    let host: String
    let port: Int

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// From the stored `host:port`; nil for anything else.
    init?(_ stored: String) {
        guard let colon = stored.lastIndex(of: ":"),
              let port = Int(stored[stored.index(after: colon)...]),
              (1...65_535).contains(port)
        else { return nil }
        let host = String(stored[..<colon])
        guard !host.isEmpty else { return nil }
        self.init(host: host, port: port)
    }

    var stored: String { "\(host):\(port)" }
}
