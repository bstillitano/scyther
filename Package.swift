// swift-tools-version:6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Scyther",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "Scyther",
            targets: ["Scyther"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.0"),
    ],
    targets: [
        // Installs the `URLSessionConfiguration` hooks at image load, before any host code runs.
        // Objective-C because Swift has no `+load` or constructor.
        .target(
            name: "ScytherBootstrap",
            path: "Sources/ScytherBootstrap"
        ),
        .target(
            name: "Scyther",
            dependencies: ["ScytherBootstrap"],
            path: "Sources/Scyther",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "ScytherTests",
            dependencies: ["Scyther", "ScytherBootstrap"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
    ],
    swiftLanguageVersions: [.v6]
)
