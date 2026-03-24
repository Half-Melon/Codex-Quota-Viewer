// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexAccountSwitcher",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(
            name: "CodexAccountSwitcher",
            targets: ["CodexAccountSwitcher"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-testing.git", exact: "6.2.4"),
    ],
    targets: [
        .executableTarget(
            name: "CodexAccountSwitcher",
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "CodexAccountSwitcherTests",
            dependencies: [
                "CodexAccountSwitcher",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
