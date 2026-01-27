// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "Commander",
    platforms: [
        .macOS(.v10_15),
    ],
    products: [
        .library(name: "Commander", targets: ["Commander"]),
    ],
    targets: [
        .target(
            name: "Commander",
            path: "Sources/Commander"),
    ])
