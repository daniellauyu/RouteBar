import Foundation

/// RouteBar 把节点交给 Surge 的方式。
///
/// 两条路各有代价，所以做成选项而不是二选一写死：
///
/// - `.profile` 直接改写托管配置的 `[Proxy]` 段。好处是 Surge 不依赖 RouteBar 在不在运行；
///   代价是**整段被替换**——那一段里除 RouteBar 之外的任何代理都会在下次生成时消失。
/// - `.subscription` 起一个本地 HTTP 服务，让 Surge 用 `policy-path=` 拉取（和 sub.store
///   完全同一个机制）。好处是不碰配置文件，可以和 sub.store 之类的外部订阅共存；
///   代价是**只在 RouteBar 运行时可用**（Surge 会缓存上一次的结果，所以不是硬失败）。
public enum SurgeOutputMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case profile
    case subscription
    case both

    public nonisolated var id: String { rawValue }

    public nonisolated var label: String {
        switch self {
        case .profile: "写入 Surge 配置"
        case .subscription: "本地订阅地址"
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
