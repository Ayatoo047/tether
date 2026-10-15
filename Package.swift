// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Tether",
    platforms: [.macOS(.v14)],
    targets: [
        // libmtp: Android's built-in USB "File transfer" protocol (no Developer mode needed).
        .systemLibrary(
            name: "CLibMTP",
            path: "Sources/CLibMTP",
            pkgConfig: "libmtp",
            providers: [.brew(["libmtp"])]
        ),
        .executableTarget(
            name: "Tether",
            dependencies: ["CLibMTP"],
            path: "Sources/Tether"
        ),
    ]
)
