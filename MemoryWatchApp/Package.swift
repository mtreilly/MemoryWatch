// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MemoryWatch",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MemoryWatch", targets: ["MemoryWatch"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "MemoryWatch",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "MemoryWatchTests",
            dependencies: ["MemoryWatch"],
            path: "Tests/MemoryWatchTests"
        )
    ]
)
