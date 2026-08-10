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

    // 快照创建时一次性计算的派生状态。界面一次刷新会读取这些字段很多次，不能每次都重新
    // merge + sort 全部节点；节点多时那会直接占满一帧的主线程预算。
    public let mergedNodes: [ProxyNode]
    public let enabledNodes: [ProxyNode]
    public let rawNodeCount: Int
    public let deduplicatedCount: Int
    public let deduplicationRate: Double
    public let testedNodeCount: Int
    public let failedLatencyCount: Int
    public let enabledSubscriptionCount: Int
    public let failedSubscriptionCount: Int
    public let nextUpdateDate: Date?
    public let healthMessages: [String]
    public let overall: OverallStatus
    public let menuBarSummary: String

    /// 当前生效的节点命名规则（全局模板 + 各订阅的覆盖）。
    ///
    /// 生成配置和本地订阅服务都从这里取，两条路径因此不可能给同一个端口起两个名字。
    public nonisolated var nodeNaming: NodeNaming {
        NodeNaming(settings: settings, subscriptions: subscriptions)
    }

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
        let merged = NodeCatalog.merge(subscriptions.filter(\.isEnabled).flatMap(\.nodes))
        let enabled = merged.filter(\.isEnabled)
        let rawCount = subscriptions.reduce(0) { $0 + $1.nodes.count }
        let deduplicated = max(0, rawCount - merged.count)
        let enabledSubscriptions = subscriptions.filter(\.isEnabled).count
        let failedSubscriptions = subscriptions.filter { $0.status == .failed }.count
        var messages: [String] = []
        if subscriptions.isEmpty { messages.append("还没有订阅，先添加一个订阅地址。") }
        if failedSubscriptions > 0 { messages.append("\(failedSubscriptions) 个订阅最近更新失败。") }
        if enabledSubscriptions > 0 && enabled.isEmpty {
            messages.append("当前没有启用节点，没有任何本地出口可供代理客户端使用。")
        }
        if environment.singBoxBinary == .missing { messages.append("未找到 sing-box 可执行文件，请在「环境」页确认路径。") }
        if environment.launchAgent == .missing { messages.append("LaunchAgent 未找到，sing-box 可能无法由 RouteBar 管理。") }
        // 只在真的要写 Surge 配置时才提。用订阅地址接别的客户端（甚至只用环境变量走
        // curl）的人没有那个文件，无条件报缺失等于给他们一条永远修不好的警告。
        if settings.outputMode.writesProfile, environment.surgeProfile == .missing {
            messages.append("Surge 托管配置未找到，需要先生成或确认配置路径。")
        }
        if let reason = serviceState.failureReason { messages.append("sing-box 状态异常：\(reason)") }

        let status: OverallStatus
        if case .failed = serviceState {
            status = .failed
        } else if !messages.isEmpty {
            status = .needsAttention
        } else {
            status = serviceState.isRunning ? .running : .stopped
        }

        mergedNodes = merged
        enabledNodes = enabled
        rawNodeCount = rawCount
        deduplicatedCount = deduplicated
        deduplicationRate = rawCount == 0 ? 0 : Double(deduplicated) / Double(rawCount)
        testedNodeCount = merged.lazy.filter { $0.latency != nil }.count
        failedLatencyCount = merged.lazy.filter { $0.latency != nil && $0.latency?.outcome != .success }.count
        enabledSubscriptionCount = enabledSubscriptions
        failedSubscriptionCount = failedSubscriptions
        nextUpdateDate = autoUpdatePaused
            ? nil
            : subscriptions.filter(\.isEnabled).compactMap { UpdateSchedule.nextUpdate(for: $0) ?? .now }.min()
        healthMessages = messages
        overall = status
        switch status {
        case .running: menuBarSummary = "运行中 · \(enabled.count) 个节点在线"
        case .stopped: menuBarSummary = "sing-box 已停止 · \(enabled.count) 个节点待用"
        case .needsAttention: menuBarSummary = "\(messages.count) 项待处理 · \(enabled.count) 个节点"
        case .failed: menuBarSummary = "sing-box 异常 · 请查看服务页"
        }
    }
}
