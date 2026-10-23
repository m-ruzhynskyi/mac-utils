// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacUtils",
    platforms: [.macOS(.v14)],
    targets: [
        // Удалённые подключения: вся логика без зависимости от приложения (см. .audit/task-remote-connections.md).
        .target(
            name: "MURemoteConnections",
            path: "Sources/MURemoteConnections"
        ),
        .executableTarget(
            name: "MacUtils",
            dependencies: ["MURemoteConnections"],
            path: "Sources/MacUtils"
        ),
        .executableTarget(
            name: "ToolsLauncher",
            path: "Sources/ToolsLauncher"
        ),
        .testTarget(
            name: "MURemoteConnectionsTests",
            dependencies: ["MURemoteConnections"],
            path: "Tests/MURemoteConnectionsTests"
        ),
        .testTarget(
            name: "MacUtilsTests",
            dependencies: ["MacUtils"],
            path: "Tests/MacUtilsTests"
        ),
    ]
)
