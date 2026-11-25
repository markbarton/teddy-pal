// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClawPalMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClawPalCore", targets: ["ClawPalCore"]),
        .executable(name: "ClawPalMac", targets: ["ClawPalApp"]),
    ],
    targets: [
        .target(
            name: "ClawPalCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ClawPalApp",
            dependencies: ["ClawPalCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ClawPalChecks",
            dependencies: ["ClawPalCore"],
            path: "Tests/ClawPalCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
