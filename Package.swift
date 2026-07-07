// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RouteBarCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "RouteBarCore", targets: ["RouteBarCore"])],
    targets: [
        .target(name: "RouteBarCore", path: "RouteBar/Core"),
        .testTarget(name: "RouteBarCoreTests", dependencies: ["RouteBarCore"], path: "RouteBarCoreTests"),
    ]
)
