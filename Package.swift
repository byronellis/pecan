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
        // Pinned past 1.0.0 for the Swift 6.4 lua_CFunction ternary fix (985e19a); move back
        // to a version requirement once a release includes it.
        .package(url: "https://github.com/tomsci/LuaSwift.git", revision: "985e19af1ae62639e54e4ce2a9f7712a29b5432c"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-markdown.git", from: "0.4.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMajor(from: "3.31.3")),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
    ],
    targets: [
        // MARK: - Settings store (providers, models, server state)
        .target(
            name: "PecanSettings",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
            ],
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

        // MARK: - Core agent logic (tools, hooks, prompt composer, Lua runtime)
        .target(
            name: "PecanAgentCore",
            dependencies: [
                .product(name: "Lua", package: "LuaSwift"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Markdown", package: "swift-markdown"),
                "PecanSettings",
            ],
            path: "Sources/PecanAgentCore"
        ),

        // MARK: - Resident server (protocol host) and HTTP LLM proxy
        .target(
            name: "PecanServer",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                "PecanSettings",
                "PecanProtocol",
            ],
            path: "Sources/PecanServer"
        ),

        // MARK: - Terminal UI & Integrated Agent Client
        .executableTarget(
            name: "PecanUI",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
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
