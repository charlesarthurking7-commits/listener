// swift-tools-version: 6.2
import PackageDescription

// ListenerCore, GoogleSpeech and ClaudeAPI use no Apple-only frameworks, so they
// build and test on Linux too. Everything that touches AppKit, AVFoundation or
// Core Audio lives in ListenerMac and the app target.
var products: [Product] = [.library(name: "ListenerCore", targets: ["ListenerCore"])]
var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.0"),
    .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.11.0"),
    .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.5.0"),
    .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.39.0"),
]
var targets: [Target] = [
    .target(name: "ListenerCore"),
    .target(
        name: "GoogleSpeech",
        dependencies: [
            "ListenerCore",
            .product(name: "GRPCCore", package: "grpc-swift-2"),
            .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
            .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
        ]
    ),
    .target(name: "ClaudeAPI", dependencies: ["ListenerCore"]),
    .testTarget(name: "ListenerCoreTests", dependencies: ["ListenerCore"]),
    .testTarget(
        name: "GoogleSpeechTests",
        dependencies: [
            "GoogleSpeech",
            .product(name: "GRPCCore", package: "grpc-swift-2"),
            .product(name: "GRPCInProcessTransport", package: "grpc-swift-2"),
            .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
        ]
    ),
    .testTarget(name: "ClaudeAPITests", dependencies: ["ClaudeAPI"]),
]

#if os(macOS)
    products.append(.executable(name: "listener", targets: ["ListenerApp"]))
    // Parakeet speech recognition for dictation. Its optional text normaliser trait is
    // left out: Claude tidies the text instead.
    dependencies.append(.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: []))
    targets += [
        .target(
            name: "ListenerMac",
            dependencies: [
                "ListenerCore",
                "ClaudeAPI",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .executableTarget(
            name: "ListenerApp",
            dependencies: [
                "ListenerCore",
                "ListenerMac",
                "GoogleSpeech",
                "ClaudeAPI",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ]
#endif

let package = Package(
    name: "Listener",
    platforms: [.macOS(.v15)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
