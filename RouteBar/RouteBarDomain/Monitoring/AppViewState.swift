import Foundation

/// 整体状态（菜单栏图标与概览页的总体反馈）。
public enum OverallStatus: String, Sendable, Equatable {
    case running
    case stopped
    case needsAttention
    case failed

    public nonisolated var label: String {
        switch self {
        case .running: "运行正常"
        case .stopped: "服务已停止"
        case .needsAttention: "需要处理"
        case .failed: "服务异常"
        }
    }
}

/// 统一视图状态。
///
/// 菜单栏面板与主窗口读的是同一份快照，界面之间不会各算各的（原来订阅数、节点数、
/// 服务状态散落在 AppModel 的十几个 `@Published` 里，两处显示不一致就只能靠肉眼发现）。
/// 引擎（`SubscriptionCoordinator`）每完成一次操作就产出一份新的，界面只负责渲染。
public struct AppViewState: Sendable {
    public let subscriptions: [SubscriptionRecord]
    public let serviceState: ServiceState
    public let environment: RouteBarEnvironmentReport
    public let settings: RouteBarSettings
    public let autoUpdatePaused: Bool
    /// 上次成功生成的端口映射（节点页展示本地端口、测速都用它）。
    public let mappedNodes: [PortMappedNode]
    public let generatedAt: Date?

    public nonisolated init(
        subscriptions: [SubscriptionRecord],
        serviceState: ServiceState,
        environment: RouteBarEnvironmentReport,
        settings: RouteBarSettings,
        autoUpdatePaused: Bool,
        mappedNodes: [PortMappedNode] = [],
        generatedAt: Date? = nil
    ) {
        self.subscriptions = subscriptions
        self.serviceState = serviceState
        self.environment = environment
        self.settings = settings
        self.autoUpdatePaused = autoUpdatePaused
        self.mappedNodes = mappedNodes
        self.generatedAt = generatedAt
    }

    // MARK: - 节点

    /// 启用订阅下的全部节点，按指纹去重。
    public nonisolated var mergedNodes: [ProxyNode] {
        NodeCatalog.merge(subscriptions.filter(\.isEnabled).flatMap(\.nodes))
    }

    public nonisolated var enabledNodes: [ProxyNode] { mergedNodes.filter(\.isEnabled) }
    public nonisolated var rawNodeCount: Int { subscriptions.reduce(0) { $0 + $1.nodes.count } }
    public nonisolated var deduplicatedCount: Int { max(0, rawNodeCount - mergedNodes.count) }
    public nonisolated var deduplicationRate: Double {
        rawNodeCount == 0 ? 0 : Double(deduplicatedCount) / Double(rawNodeCount)
    }

    public nonisolated var testedNodeCount: Int { mergedNodes.filter { $0.latency != nil }.count }
    public nonisolated var failedLatencyCount: Int {
        mergedNodes.filter { $0.latency != nil && $0.latency?.outcome != .success }.count
    }

    // MARK: - 订阅

    public nonisolated var enabledSubscriptionCount: Int { subscriptions.filter(\.isEnabled).count }
    public nonisolated var failedSubscriptionCount: Int { subscriptions.filter { $0.status == .failed }.count }

    public nonisolated var nextUpdateDate: Date? {
        guard !autoUpdatePaused else { return nil }
        return subscriptions.filter(\.isEnabled).compactMap { UpdateSchedule.nextUpdate(for: $0) ?? .now }.min()
    }

    // MARK: - 总体状态

    /// 自检项：每条都是用户能直接动手解决的问题，不摆纯信息。
    public nonisolated var healthMessages: [String] {
        var messages: [String] = []
        if subscriptions.isEmpty { messages.append("还没有订阅，先添加一个订阅地址。") }
        if failedSubscriptionCount > 0 { messages.append("\(failedSubscriptionCount) 个订阅最近更新失败。") }
        if enabledSubscriptionCount > 0 && enabledNodes.isEmpty {
            messages.append("当前没有启用节点，Surge 分流会缺少可选代理。")
        }
        if environment.singBoxBinary == .missing { messages.append("未找到 sing-box 可执行文件，请在「环境」页确认路径。") }
        if environment.launchAgent == .missing { messages.append("LaunchAgent 未找到，sing-box 可能无法由 RouteBar 管理。") }
        if environment.surgeProfile == .missing { messages.append("Surge 托管配置未找到，需要先生成或确认配置路径。") }
        if let reason = serviceState.failureReason { messages.append("sing-box 状态异常：\(reason)") }
        return messages
    }

    public nonisolated var overall: OverallStatus {
        if case .failed = serviceState { return .failed }
        if !healthMessages.isEmpty { return .needsAttention }
        return serviceState.isRunning ? .running : .stopped
    }

    /// 菜单栏面板标题下的一行摘要。
    public nonisolated var menuBarSummary: String {
        switch overall {
        case .running: "运行中 · \(enabledNodes.count) 个节点在线"
        case .stopped: "sing-box 已停止 · \(enabledNodes.count) 个节点待用"
        case .needsAttention: "\(healthMessages.count) 项待处理 · \(enabledNodes.count) 个节点"
        case .failed: "sing-box 异常 · 请查看服务页"
        }
    }
}
