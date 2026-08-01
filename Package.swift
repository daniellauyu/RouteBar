// swift-tools-version: 6.0
import PackageDescription

// 这个包只是 Domain 层的测试载体：Xcode 工程用文件系统同步组直接编译 RouteBar/ 下的
// 全部源码，Domain 里的类型在应用里无需 import。单独成包是为了能用 `swift test`
// 跑纯逻辑测试，不必启动整个 app。Core 层有 I/O 与 actor，不放进来。
let package = Package(
    name: "RouteBarDomain",
    platforms: [.macOS(.v15)],
    products: [.library(name: "RouteBarDomain", targets: ["RouteBarDomain"])],
    targets: [
        .target(name: "RouteBarDomain", path: "RouteBar/RouteBarDomain"),
        .testTarget(name: "RouteBarDomainTests", dependencies: ["RouteBarDomain"], path: "RouteBarDomainTests"),
    ]
)
