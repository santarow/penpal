// swift-tools-version: 6.0
import PackageDescription

// Penpal: the Mac app. Its engine (bin/kite) runs your own Claude through Claude Code.
let package = Package(
    name: "Kite",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Kite", path: "Sources/Kite",
                          swiftSettings: [.define("PENPAL_ONLY")])
    ]
)
