// swift-tools-version: 6.0
import PackageDescription

// ListenerCore is plain Foundation so it builds and tests on Linux too.
// Everything that touches Apple frameworks lives in ListenerMac and the app target.
var products: [Product] = []
var targets: [Target] = [
    .target(name: "ListenerCore"),
    .testTarget(name: "ListenerCoreTests", dependencies: ["ListenerCore"]),
]

#if os(macOS)
    products.append(.executable(name: "listener", targets: ["ListenerApp"]))
    targets += [
        .target(name: "ListenerMac", dependencies: ["ListenerCore"]),
        .executableTarget(
            name: "ListenerApp",
            dependencies: [
                "ListenerCore",
                "ListenerMac",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ]
#endif

let package = Package(
    name: "Listener",
    platforms: [.macOS(.v15)],
    products: products,
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: targets
)
