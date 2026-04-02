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
        .package(url: "https://github.com/swiftlang/swift-testing.git", revision: "swift-6.2-RELEASE"),
    ],
    targets: [
        .executableTarget(
            name: "CodexQuotaViewer",
            path: "Sources/CodexQuotaViewer",
            exclude: ["Resources"]
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
