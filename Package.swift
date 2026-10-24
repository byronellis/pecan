// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "pecan",
    platforms: [
        .macOS(.v27)
    ],
    products: [
        .executable(name: "pecan", targets: ["PecanUI"]),
        .library(name: "PecanAgentCore", targets: ["PecanAgentCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.4"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-markdown.git", from: "0.4.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.0"),
    ],
    targets: [
        // MARK: - Build identity and per-channel paths
        .target(
            name: "PecanSettings",
            path: "Sources/PecanSettings"
        ),

        // MARK: - Client/server protocol, connect-or-start, upgrade handshake
        .target(
            name: "PecanProtocol",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                "PecanSettings",
            ],
            path: "Sources/PecanProtocol"
        ),

        // MARK: - Core agent logic (tools, prompt composer)
        .target(
            name: "PecanAgentCore",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Markdown", package: "swift-markdown"),
                "PecanSettings",
            ],
            path: "Sources/PecanAgentCore"
        ),

        // MARK: - Resident server: protocol host and model sessions
        .target(
            name: "PecanServer",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                "PecanSettings",
                "PecanProtocol",
            ],
            path: "Sources/PecanServer"
        ),

        // MARK: - Terminal UI & Integrated Agent Client
        .executableTarget(
            name: "PecanUI",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                "PecanSettings",
                "PecanAgentCore",
                "PecanServer",
                "PecanProtocol",
            ],
            path: "Sources/PecanUI"
        ),

        .testTarget(
            name: "PecanUITests",
            dependencies: ["PecanUI"],
            path: "Tests/PecanUITests"
        ),
    ]
)
