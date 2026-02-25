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
        // Dependencies for gRPC and related tools will be added here
    ],
    targets: [
        .executableTarget(
            name: "PecanServer",
            dependencies: []),
        .executableTarget(
            name: "PecanUI",
            dependencies: []),
        .executableTarget(
            name: "PecanAgent",
            dependencies: []),
    ]
)
