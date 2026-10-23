// swift-tools-version:5.9
//
// Studio-mode spike (vault: todo/205, decisions/studio-mode-on-desktop.md). Not part of the app:
// it proves the lossless audio path — capture, FLAC, a WebRTC data channel, playout — before any
// of it is built into Construct Desktop.

import Foundation
import PackageDescription

// A command-line tool has no bundle, so the usage string the audio-capture permission needs is
// linked into the binary's __info_plist section.
let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Sources/studio-spike/Info.plist").path

let package = Package(
    name: "StudioSpike",
    platforms: [.macOS("14.2")],
    dependencies: [
        .package(path: "../../Packages/WebRTC"),
    ],
    targets: [
        .target(name: "StudioCore"),
        .target(name: "StudioLink", dependencies: ["StudioCore", .product(name: "WebRTC", package: "WebRTC")]),
        .executableTarget(
            name: "studio-spike",
            dependencies: ["StudioCore", "StudioLink"],
            exclude: ["Info.plist"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                                           "-Xlinker", "__info_plist", "-Xlinker", infoPlist])]
        ),
        .testTarget(name: "StudioCoreTests", dependencies: ["StudioCore"]),
    ]
)
