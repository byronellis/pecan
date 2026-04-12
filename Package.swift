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
        .executable(name: "pecan-shell", targets: ["PecanShell"]),
        .executable(name: "pecan-mock-llm", targets: ["PecanMockLLM"]),
        .library(name: "PecanServerCore", targets: ["PecanServerCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/byronellis/pecan-shared.git", branch: "main"),
        .package(url: "https://github.com/pakLebah/ANSITerminal.git", from: "0.0.3"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.4"),
        .package(url: "https://github.com/tomsci/LuaSwift.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/containerization.git", branch: "main"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift.git", from: "1.27.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
    ],
    targets: [
        // MARK: - Testable core library (pure logic, no gRPC/container deps)
        .target(
            name: "PecanServerCore",
            dependencies: [],
            path: "Sources/PecanServerCore"
        ),

        // MARK: - Mock LLM server for integration testing
        .executableTarget(
            name: "PecanMockLLM",
            dependencies: [],
            path: "Sources/PecanMockLLM"
        ),

        // MARK: - Production targets
        .executableTarget(
            name: "PecanTestClient",
            dependencies: [
                .product(name: "PecanShared", package: "pecan-shared"),
            ]),
        .executableTarget(
            name: "PecanServer",
            dependencies: [
                .product(name: "PecanShared", package: "pecan-shared"),
                .product(name: "GRDB", package: "GRDB.swift"),
                "PecanServerCore",
            ]),
        .executableTarget(
            name: "PecanVMLauncher",
            dependencies: [
                .product(name: "PecanShared", package: "pecan-shared"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationEXT4", package: "containerization"),
                .product(name: "ContainerizationArchive", package: "containerization"),
                .product(name: "Logging", package: "swift-log"),
            ]),
        .executableTarget(
            name: "PecanUI",
            dependencies: [
                .product(name: "PecanShared", package: "pecan-shared"),
                .product(name: "ANSITerminal", package: "ANSITerminal"),
            ]),
        .executableTarget(
            name: "PecanAgent",
            dependencies: [
                .product(name: "PecanShared", package: "pecan-shared"),
                .product(name: "Lua", package: "LuaSwift"),
            ]),
        .executableTarget(
            name: "PecanShell",
            dependencies: [
                .product(name: "PecanShared", package: "pecan-shared"),
            ]),

        // MARK: - Test targets
        .testTarget(
            name: "PecanCoreTests",
            dependencies: ["PecanServerCore"],
            path: "Tests/PecanCoreTests"
        ),
        .testTarget(
            name: "PecanIntegrationTests",
            dependencies: [
                .product(name: "PecanShared", package: "pecan-shared"),
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "NIO", package: "swift-nio"),
            ],
            path: "Tests/PecanIntegrationTests"
        ),
    ]
)
