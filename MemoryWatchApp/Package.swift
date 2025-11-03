// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MemoryWatch",
    platforms: [
        .macOS(.v13)
    ],
products: [
    .executable(name: "MemoryWatch", targets: ["MemoryWatchCLI"]),
    .executable(name: "MemoryWatchMenuBar", targets: ["MemoryWatchMenuBar"])
],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.2.0")
    ],
    targets: [
        .target(
            name: "MemoryWatchCore",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/MemoryWatch",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "MemoryWatchCLI",
            dependencies: [
                "MemoryWatchCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/MemoryWatchCLI"
        ),
        .executableTarget(
            name: "MemoryWatchMenuBar",
            dependencies: [
                "MemoryWatchCore"
            ],
            path: "Sources/MenuBarApp"
        ),
        .testTarget(
            name: "MemoryWatchTests",
            dependencies: ["MemoryWatchCore"],
            path: "Tests/MemoryWatchTests"
        )
    ]
)
