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
    ],
    dependencies: [
        .package(url: "https://github.com/byronellis/pecan-shared.git", branch: "main"),
        .package(url: "https://github.com/pakLebah/ANSITerminal.git", from: "0.0.3"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.4"),
        .package(url: "https://github.com/tomsci/LuaSwift.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/containerization.git", branch: "main"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
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
    ]
)
