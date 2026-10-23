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
        .target(
            name: "MUCutPaste",
            dependencies: ["MUCore", "MUDesign"],
            path: "Sources/MUCutPaste"
        ),
        .target(
            name: "MUFocus",
            dependencies: ["MUCore", "MUDesign"],
            path: "Sources/MUFocus"
        ),
        .target(
            name: "MUSmoothScroll",
            dependencies: ["MUCore", "MUDesign"],
            path: "Sources/MUSmoothScroll"
        ),
        .target(
            name: "MUAppSwitcher",
            dependencies: ["MUCore", "MUDesign"],
            path: "Sources/MUAppSwitcher"
        ),
        .target(
            name: "MUUninstaller",
            dependencies: ["MUCore", "MUDesign"],
            path: "Sources/MUUninstaller"
        ),
        .executableTarget(
            name: "MacUtils",
            dependencies: ["MUCore", "MUDesign", "MUCutPaste", "MUFocus", "MUSmoothScroll", "MUAppSwitcher", "MUUninstaller"],
            path: "Sources/MacUtils"
        ),
        .executableTarget(
            name: "ToolsLauncher",
            path: "Sources/ToolsLauncher"
        ),
        .testTarget(
            name: "MacUtilsTests",
            dependencies: ["MacUtils", "MUCore", "MUDesign", "MUCutPaste", "MUFocus", "MUSmoothScroll", "MUAppSwitcher", "MUUninstaller"],
            path: "Tests/MacUtilsTests"
        ),
    ]
)
