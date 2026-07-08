// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NIOForwarder",
    platforms: [
        .macOS(.v10_15),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "NIOForwarder",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Atomics", package: "swift-atomics"),
            ]
        ),
    ]
)
