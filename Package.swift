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
    ],
    targets: [
        .target(
            name: "NoCoKit",
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
