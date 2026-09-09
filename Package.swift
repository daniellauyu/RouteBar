// swift-tools-version: 6.0
import PackageDescription

// 以同一模块编译 Domain 和 Core，保持与 Xcode 应用一致的符号可见性。
// 测试使用临时目录和受控子进程，不启动应用或操作用户的真实配置。
let package = Package(
    name: "RouteBarDomain",
    platforms: [.macOS(.v14)],
    products: [.library(name: "RouteBarDomain", targets: ["RouteBarDomain"])],
    targets: [
        .target(name: "RouteBarDomain", path: "RouteBar",
                exclude: ["RouteBarApp", "RouteBarApp.swift", "ContentView.swift", "Assets.xcassets"],
                sources: ["RouteBarDomain", "RouteBarCore"]),
        .testTarget(name: "RouteBarDomainTests", dependencies: ["RouteBarDomain"], path: "RouteBarDomainTests"),
    ]
)
