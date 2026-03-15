// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NoCo",
    platforms: [.iOS(.v18), .macOS(.v15)],
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
        .package(url: "https://github.com/apple/swift-nio-http2", from: "1.34.0"),
    ],
    targets: [
        .target(
            name: "CNodeAPI",
            path: "Sources/CNodeAPI",
            publicHeadersPath: "include"
        ),
        .target(
            name: "NoCoKit",
            dependencies: [
                "CNodeAPI",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
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
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-exported_symbols_list",
                    "-Xlinker", "\(Context.packageDirectory)/napi_exports.txt",
                ]),
            ]
        ),
        .testTarget(
            name: "NoCoKitTests",
            dependencies: [
                "NoCoKit",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
            ],
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
