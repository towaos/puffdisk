// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PuffdiskCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PuffdiskCore", targets: ["PuffdiskCore"]),
    ],
    targets: [
        // ファイル操作をしない判定ロジック（DESIGN.md 9.4）と走査の部品
        .target(name: "PuffdiskCore"),
        // M0 検証スパイク用の CLI（DESIGN.md 13.1）。配布物には含めない
        .executableTarget(
            name: "puffdisk-spikes",
            dependencies: ["PuffdiskCore"],
            path: "Sources/Spikes",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "PuffdiskCoreTests", dependencies: ["PuffdiskCore"]),
    ]
)
