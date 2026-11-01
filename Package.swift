// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tethr",
    platforms: [.iOS(.v17), .tvOS(.v17), .macOS(.v14), .visionOS(.v1)],
    products: [
        .library(name: "Tethr", targets: ["Tethr"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.13.1"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.3.2"),
        .package(url: "https://github.com/apple/swift-http-types", from: "1.8.0"),
    ],
    targets: [
        .target(
            name: "Tethr",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            exclude: ["Generated/openapi-generator-config.yaml"]
        ),
        .testTarget(
            name: "TethrTests",
            dependencies: [
                "Tethr",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ]
        ),
    ]
)
