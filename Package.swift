// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "pecan",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "pecan-server", targets: ["PecanServer"]),
        .executable(name: "pecan-vm-launcher", targets: ["PecanVMLauncher"]),
        .executable(name: "pecan-test-client", targets: ["PecanTestClient"]),
        .executable(name: "pecan", targets: ["PecanUI"]),
        .executable(name: "pecan-agent", targets: ["PecanAgent"]),
        .executable(name: "pecan-mlx-server", targets: ["PecanMLXServer"]),
        .executable(name: "pecan-shell", targets: ["PecanShell"]),
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift.git", from: "1.23.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.25.2"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.6"),
        .package(url: "https://github.com/pakLebah/ANSITerminal.git", from: "0.0.3"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.4"),
        .package(url: "https://github.com/tomsci/LuaSwift.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/containerization.git", branch: "main"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "2.30.3"),
    ],
    targets: [
        .target(
            name: "PecanShared",
            dependencies: [
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "Logging", package: "swift-log"),
            ],
            exclude: [
                "pecan.proto",
                "swift-protobuf-config.json",
                "grpc-swift-config.json"
            ]
        ),
        .executableTarget(
            name: "PecanTestClient",
            dependencies: [
                "PecanShared",
            ]),
.executableTarget(
            name: "PecanServer",
            dependencies: [
                "PecanShared",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]),
        .executableTarget(
            name: "PecanVMLauncher",
            dependencies: [
                "PecanShared",
                .product(name: "Containerization", package: "containerization"),
                .product(name: "Logging", package: "swift-log"),
            ]),
        .executableTarget(
            name: "PecanUI",
            dependencies: [
                "PecanShared",
                .product(name: "ANSITerminal", package: "ANSITerminal")
            ]),
        .executableTarget(
            name: "PecanAgent",
            dependencies: [
                "PecanShared",
                .product(name: "Lua", package: "LuaSwift")
            ]),
        .executableTarget(
            name: "PecanMLXServer",
            dependencies: [
                "PecanShared",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Logging", package: "swift-log"),
            ]),
        .executableTarget(
            name: "PecanShell",
            dependencies: [
                "PecanShared",
            ]),
    ]
)
