// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ClaudeBridge",
    platforms: [.macOS(.v15)],
    products: [.library(name: "BridgeCore", targets: ["BridgeCore"])],
    targets: [
        .target(name: "BridgeCore", path: "Sources/BridgeCore"),
        .testTarget(name: "BridgeCoreTests", dependencies: ["BridgeCore"], path: "tests/BridgeCoreTests")
    ]
)
