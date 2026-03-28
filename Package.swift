// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CodexQuotaViewer",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(
            name: "CodexQuotaViewer",
            targets: ["CodexQuotaViewer"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing", exact: "6.2.4"),
    ],
    targets: [
        .executableTarget(
            name: "CodexQuotaViewer",
            path: "Sources/CodexQuotaViewer",
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "CodexQuotaViewerTests",
            dependencies: [
                "CodexQuotaViewer",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/CodexQuotaViewerTests"
        ),
    ]
)
