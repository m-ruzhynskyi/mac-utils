// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacUtils",
    platforms: [.macOS(.v14)],
    targets: [
        // Общее для всех функций: настройки, журнал, горячие клавиши, разрешения. Функций не знает.
        .target(
            name: "MUCore",
            path: "Sources/MUCore"
        ),
        // Оформление: токены, компоненты, окна-панели. Функций не знает.
        .target(
            name: "MUDesign",
            dependencies: ["MUCore"],
            path: "Sources/MUDesign"
        ),
        // Удалённые подключения: вся логика без зависимости от приложения и других модулей
        // (см. .audit/task-remote-connections.md).
        .target(
            name: "MURemoteConnections",
            path: "Sources/MURemoteConnections"
        ),
        .executableTarget(
            name: "MacUtils",
            dependencies: ["MUCore", "MUDesign", "MURemoteConnections"],
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
            dependencies: ["MacUtils", "MUCore", "MUDesign", "MURemoteConnections"],
            path: "Tests/MacUtilsTests"
        ),
    ]
)
