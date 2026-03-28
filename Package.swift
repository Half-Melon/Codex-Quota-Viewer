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
    targets: [
        .executableTarget(
            name: "CodexQuotaViewer",
            path: "Sources/CodexQuotaViewer",
            resources: [
                .process("Resources"),
            ]
        ),
    ]
)
