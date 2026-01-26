// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "imsg",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "IMsgCore", targets: ["IMsgCore"]),
        .executable(name: "imsg", targets: ["imsg"]),
    ],
    dependencies: [
        .package(url: "https://github.com/steipete/Commander.git", from: "0.2.0"),
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.15.4"),
        .package(url: "https://github.com/marmelroy/PhoneNumberKit.git", from: "4.2.2"),
    ],
    targets: [
        .target(
            name: "IMsgCore",
            dependencies: [
                .product(name: "SQLite", package: "SQLite.swift"),
                .product(name: "PhoneNumberKit", package: "PhoneNumberKit"),
            ],
            linkerSettings: [
                .linkedFramework("ScriptingBridge"),
            ]
        ),
    .executableTarget(
        name: "imsg",
        dependencies: [
            "IMsgCore",
            .product(name: "Commander", package: "Commander"),
        ],
        exclude: [
            "Resources/Info.plist",
        ],
        linkerSettings: [
            .unsafeFlags([
                "-Xlinker", "-sectcreate",
                "-Xlinker", "__TEXT",
                "-Xlinker", "__info_plist",
                "-Xlinker", "Sources/imsg/Resources/Info.plist",
            ])
        ]
    ),
        .testTarget(
            name: "IMsgCoreTests",
            dependencies: [
                "IMsgCore",
            ]
        ),
        .testTarget(
            name: "imsgTests",
            dependencies: [
                "imsg",
                "IMsgCore",
            ]
        ),
    ]
)
