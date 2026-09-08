// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "QuotaBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "QuotaBar", targets: ["QuotaBar"]),
        .library(name: "UsageCore", targets: ["UsageCore"])
    ],
    targets: [
        .target(name: "UsageCore", swiftSettings: [.enableUpcomingFeature("NonisolatedNonsendingByDefault")]),
        .executableTarget(name: "QuotaBar", dependencies: ["UsageCore"], swiftSettings: [
            .defaultIsolation(MainActor.self),
            .enableUpcomingFeature("NonisolatedNonsendingByDefault")
        ]),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"])
    ]
)
