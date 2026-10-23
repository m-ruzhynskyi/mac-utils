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
        .executableTarget(
            name: "MacUtils",
            dependencies: ["MUCore", "MUDesign"],
            path: "Sources/MacUtils"
        ),
        .executableTarget(
            name: "ToolsLauncher",
            path: "Sources/ToolsLauncher"
        ),
        .testTarget(
            name: "MacUtilsTests",
            dependencies: ["MacUtils", "MUCore", "MUDesign"],
            path: "Tests/MacUtilsTests"
        ),
    ]
)
