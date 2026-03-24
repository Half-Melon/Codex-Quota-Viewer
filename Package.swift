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
            ]
        ),
    ]
)
