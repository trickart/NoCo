// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NoCo",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .executable(
            name: "noco",
            targets: ["NoCo"]
        ),
        .library(
            name: "NoCoKit",
            targets: ["NoCoKit"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.7.0"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.95.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services", from: "1.26.0"),
    ],
    targets: [
        .target(
            name: "NoCoKit",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
            ],
            linkerSettings: [
                .linkedFramework("JavaScriptCore"),
            ]
        ),
        .executableTarget(
            name: "NoCo",
            dependencies: [
                "NoCoKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "NoCoKitTests",
            dependencies: ["NoCoKit"],
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
