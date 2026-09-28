// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SwiftUIQuery",
    platforms: [
        .iOS(.v15),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "SwiftUIQuery",
            targets: ["SwiftUIQuery"]
        )
    ],
    targets: [
        .target(
            name: "SwiftUIQuery",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "SwiftUIQueryTests",
            dependencies: ["SwiftUIQuery"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
