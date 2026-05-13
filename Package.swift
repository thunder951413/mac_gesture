// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GestureDaemon",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "GestureDaemon",
            path: "Sources/GestureDaemon"
        )
    ]
)
