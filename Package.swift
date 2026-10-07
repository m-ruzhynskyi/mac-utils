// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacUtils",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacUtils",
            path: "Sources/MacUtils"
        ),
        .testTarget(
            name: "MacUtilsTests",
            dependencies: ["MacUtils"],
            path: "Tests/MacUtilsTests"
        ),
    ]
)
