// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "foobar",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.121.4"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.11.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.15.0"),
    ],
    targets: [
        .executableTarget(
            name: "foobar",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "foobarTests",
            dependencies: ["foobar"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
