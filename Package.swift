// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "foobar",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.121.4"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.11.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.15.0"),
        .package(url: "https://github.com/apple/swift-openapi-generator.git", from: "1.13.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime.git", from: "1.12.0"),
        .package(url: "https://github.com/vapor/swift-openapi-vapor.git", from: "1.1.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.13.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.9.0")
    ],
    targets: [
        .executableTarget(
            name: "foobar",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIVapor", package: "swift-openapi-vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver")
            ],
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")
            ]
        ),
        .testTarget(
            name: "foobarTests",
            dependencies: [
                "foobar",
                .product(name: "VaporTesting", package: "vapor")
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
