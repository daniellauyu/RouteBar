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

/// 一条「需要处理」的自检结论。
///
/// 用带码的枚举而不是现成的中文句子：Web 界面可以切中英文，服务端下发写死的中文句子
/// 会让英文模式下这一栏原样露出中文。码由两边共用，文案各自出——原生窗口用下面的
/// `text`，网页用它自己的词条表。
public enum HealthIssue: Sendable, Equatable, Hashable {
    case noSubscriptions
    case failedSubscriptions(Int)
    case noEnabledNodes
    case missingSingBoxBinary
    case missingLaunchAgent
    case serviceFailure(String)

    /// 稳定标识，两个前端都按它取自己的文案。改名等于改契约。
    public nonisolated var code: String {
        switch self {
        case .noSubscriptions: "noSubscriptions"
        case .failedSubscriptions: "failedSubscriptions"
        case .noEnabledNodes: "noEnabledNodes"
        case .missingSingBoxBinary: "missingSingBoxBinary"
        case .missingLaunchAgent: "missingLaunchAgent"
        case .serviceFailure: "serviceFailure"
        }
    }

    /// 填进文案模板的参数，按出现顺序。
    public nonisolated var arguments: [String] {
        switch self {
        case .failedSubscriptions(let count): [String(count)]
        case .serviceFailure(let reason): [reason]
        default: []
        }
    }

    /// 中文文案，原生窗口直接用。
    public nonisolated var text: String {
        switch self {
        case .noSubscriptions: "还没有订阅，先添加一个订阅地址。"
        case .failedSubscriptions(let count): "\(count) 个订阅最近更新失败。"
        case .noEnabledNodes: "当前没有启用节点，没有任何本地出口可供代理客户端使用。"
        case .missingSingBoxBinary: "未找到 sing-box 可执行文件，请在「环境」页确认路径。"
        case .missingLaunchAgent: "LaunchAgent 未找到，sing-box 可能无法由 RouteBar 管理。"
        case .serviceFailure(let reason): "sing-box 状态异常：\(reason)"
        }
    }
}

/// 订阅中的一条原始节点记录。`node.id` 是可去重的连接指纹，`id` 是可独立操作的条目身份。
public struct DisplayedNode: Sendable, Identifiable {
    public let node: ProxyNode
    public let sourceID: UUID
    public let sourceName: String
    public let subscriptionEnabled: Bool
    public let localPort: Int?

    public nonisolated var id: String { node.entryID }
    public nonisolated var effectiveEnabled: Bool { subscriptionEnabled && node.isEnabled }
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
    /// 所有订阅中的全部原始条目，包括停用订阅、关闭节点和重复出口。
    public let displayedNodes: [DisplayedNode]
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
    public let healthIssues: [HealthIssue]

    /// 中文自检文案。原生窗口读它，与 `healthIssues` 同源，不会两边说法不一致。
    public nonisolated var healthMessages: [String] { healthIssues.map(\.text) }
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
        let enabled = subscriptions.filter(\.isEnabled).flatMap(\.nodes).filter(\.isEnabled)
        let rawCount = subscriptions.reduce(0) { $0 + $1.nodes.count }
        let allUnique = NodeCatalog.merge(subscriptions.flatMap(\.nodes))
        let deduplicated = max(0, rawCount - allUnique.count)
        let ports = Dictionary(mappedNodes.map { ($0.node.entryID, $0.localPort) },
                               uniquingKeysWith: { first, _ in first })
        // 和端口分配用**同一个**顺序（`NodeCatalog.precedes`）。
        //
        // 原来这里是「按订阅分组、组内按订阅给的顺序」，而端口按名称排——两套顺序叠在
        // 一起，列表左边那列序号就跳得毫无规律：76 号那一行占着 7701 端口、生成名是
        // `JSSR-01`。序号取的是节点在完整列表里的位置（这样筛选、排序都不会改变它），
        // 所以只要「完整列表」的顺序和端口顺序对齐，默认视图里它就是顺的。
        displayedNodes = subscriptions.flatMap { subscription in
            subscription.nodes.map { node in
                DisplayedNode(node: node, sourceID: subscription.id, sourceName: subscription.name,
                              subscriptionEnabled: subscription.isEnabled,
                              localPort: subscription.isEnabled && node.isEnabled ? ports[node.entryID] : nil)
            }
        }.sorted { NodeCatalog.precedes($0.node, $1.node) }
        let enabledSubscriptions = subscriptions.filter(\.isEnabled).count
        let failedSubscriptions = subscriptions.filter { $0.status == .failed }.count
        var messages: [HealthIssue] = []
        if subscriptions.isEmpty { messages.append(.noSubscriptions) }
        if failedSubscriptions > 0 { messages.append(.failedSubscriptions(failedSubscriptions)) }
        if enabledSubscriptions > 0 && enabled.isEmpty {
            messages.append(.noEnabledNodes)
        }
        if environment.singBoxBinary == .missing { messages.append(.missingSingBoxBinary) }
        if environment.launchAgent == .missing { messages.append(.missingLaunchAgent) }
        // 只在真的要写 Surge 配置时才提。用订阅地址接别的客户端（甚至只用环境变量走
        // curl）的人没有那个文件，无条件报缺失等于给他们一条永远修不好的警告。
        // 曾经这里还有一条「Surge 托管配置未找到」。改写 Surge 配置那种输出方式去掉之后，
        // RouteBar 不再依赖任何由别的应用创建的文件，这条自检也就没有对象了。
        if let reason = serviceState.failureReason { messages.append(.serviceFailure(reason)) }

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
        testedNodeCount = displayedNodes.lazy.filter { $0.node.latency != nil }.count
        failedLatencyCount = displayedNodes.lazy.filter {
            $0.node.latency != nil && $0.node.latency?.outcome != .success
        }.count
        enabledSubscriptionCount = enabledSubscriptions
        failedSubscriptionCount = failedSubscriptions
        nextUpdateDate = autoUpdatePaused
            ? nil
            : subscriptions.filter(\.isEnabled).compactMap { UpdateSchedule.nextUpdate(for: $0) ?? .now }.min()
        healthIssues = messages
        overall = status
        switch status {
        case .running: menuBarSummary = "运行中 · \(enabled.count) 个节点在线"
        case .stopped: menuBarSummary = "sing-box 已停止 · \(enabled.count) 个节点待用"
        case .needsAttention: menuBarSummary = "\(messages.count) 项待处理 · \(enabled.count) 个节点"
        case .failed: menuBarSummary = "sing-box 异常 · 请查看服务页"
        }
    }
}
