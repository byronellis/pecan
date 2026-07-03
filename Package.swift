// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "pecan",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "pecan", targets: ["PecanUI"]),
        .library(name: "PecanAgentCore", targets: ["PecanAgentCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pakLebah/ANSITerminal.git", from: "0.0.3"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.4"),
        .package(url: "https://github.com/tomsci/LuaSwift.git", from: "1.0.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-markdown.git", from: "0.4.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMajor(from: "3.31.3")),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        // MARK: - Settings store (providers, models, server state)
        .target(
            name: "PecanSettings",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/PecanSettings"
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

        // MARK: - HTTP LLM Proxy Server
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
            ],
            path: "Sources/PecanServer"
        ),

        // MARK: - Terminal UI & Integrated Agent Client
        .executableTarget(
            name: "PecanUI",
            dependencies: [
                .product(name: "ANSITerminal", package: "ANSITerminal"),
                .product(name: "Markdown", package: "swift-markdown"),
                "PecanSettings",
                "PecanAgentCore",
                "PecanServer",
            ],
            path: "Sources/PecanUI"
        ),
    ]
)
