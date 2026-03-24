// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexQuickSwitch",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(
            name: "CodexQuickSwitch",
            targets: ["CodexQuickSwitch"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-testing.git", exact: "6.2.4"),
    ],
    targets: [
        .executableTarget(
            name: "CodexQuickSwitch",
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "CodexQuickSwitchTests",
            dependencies: [
                "CodexQuickSwitch",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
