// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GestureDaemon",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(
            name: "GestureTouchCore",
            path: "Sources/GestureTouchCore"
        ),
        .executableTarget(
            name: "GestureTouchService",
            dependencies: ["GestureTouchCore"],
            path: "Sources/GestureTouchService"
        ),
        .executableTarget(
            name: "GestureDaemon",
            dependencies: ["GestureTouchCore"],
            path: "Sources/GestureDaemon"
        ),
        .testTarget(
            name: "GestureDaemonTests",
            dependencies: ["GestureDaemon", "GestureTouchCore"],
            path: "Tests/GestureDaemonTests",
            resources: [.process("Fixtures")]
        )
    ]
)
