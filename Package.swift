// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "pecan",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "pecan-server", targets: ["PecanServer"]),
        .executable(name: "pecan", targets: ["PecanUI"]),
        .executable(name: "pecan-agent", targets: ["PecanAgent"]),
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift.git", from: "1.23.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.25.2"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.6"),
        .package(url: "https://github.com/pakLebah/ANSITerminal.git", from: "0.0.3"),
    ],
    targets: [
        .target(
            name: "PecanShared",
            dependencies: [
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "Yams", package: "Yams"),
            ],
            exclude: [
                "pecan.proto",
                "swift-protobuf-config.json",
                "grpc-swift-config.json"
            ]
        ),
        .executableTarget(
            name: "PecanServer",
            dependencies: ["PecanShared"]),
        .executableTarget(
            name: "PecanUI",
            dependencies: [
                "PecanShared",
                .product(name: "ANSITerminal", package: "ANSITerminal")
            ]),
        .executableTarget(
            name: "PecanAgent",
            dependencies: ["PecanShared"]),
    ]
)
