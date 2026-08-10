import Foundation

/// 额外为 Surge 准备哪种现成接法。
///
/// **先说清楚这个枚举不决定什么**：每个启用节点在本机的那个端口（`127.0.0.1:7701` 起，
/// 同端口同时收 SOCKS5 和 HTTP）是无条件存在的，任何支持代理的客户端直接填端口就能用，
/// 跟这里选哪一项毫无关系。RouteBar 的产出是那批端口，这里选的只是「要不要再替 Surge
/// 铺一层」——不用 Surge 的人两项都不必管。
///
/// 两个选项吐的都是 Surge 语法（`[Proxy]` 段 / policy 行），所以名字里保留 Surge 是准确的，
/// 不是把通用能力说窄了。各有代价，因此做成选项而不是二选一写死：
///
/// - `.profile` 直接改写托管配置的 `[Proxy]` 段。好处是 Surge 不依赖 RouteBar 在不在运行；
///   代价是**整段被替换**——那一段里除 RouteBar 之外的任何代理都会在下次生成时消失。
/// - `.subscription` 起一个本地 HTTP 服务，让 Surge 用 `policy-path=` 拉取（和 sub.store
///   完全同一个机制）。好处是不碰配置文件，可以和 sub.store 之类的外部订阅共存；
///   代价是**只在 RouteBar 运行时可用**（Surge 会缓存上一次的结果，所以不是硬失败）。
public enum OutputMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case profile
    case subscription
    case both

    public nonisolated var id: String { rawValue }

    public nonisolated var label: String {
        switch self {
        case .profile: "写入 Surge 配置"
        // 标上「Surge 格式」不是多余的：这个地址吐的是 policy 行，别的客户端拿去用不了，
        // 它们要的是节点页上的端口。不写清楚的话，用 Clash 的人会以为这是给他们的。
        case .subscription: "本地订阅地址（Surge 格式）"
        case .both: "两者都要"
        }
    }

    public nonisolated var writesProfile: Bool {
        self == .profile || self == .both
    }

    public nonisolated var servesSubscription: Bool {
        self == .subscription || self == .both
    }
}
