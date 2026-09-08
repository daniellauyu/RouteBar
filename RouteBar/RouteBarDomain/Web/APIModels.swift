import Foundation

/// Web 界面拿到的整份快照。
///
/// 这是 `AppViewState` 的**投影**而不是它本身。两者刻意分开：`SubscriptionRecord`、
/// `ProxyNode` 那几个类型的 `Codable` 是为落盘服务的，字段改名、加字段都由存储需要驱动；
/// 让它们同时充当对外契约，等于每次改存储格式都会静默改掉 API。
///
/// 另外这里**不含任何凭据**：订阅地址（含机场令牌）留在钥匙串，节点的 VLESS UUID、
/// 公钥、shortID 一概不出现——网页只需要知道「哪个节点、占哪个本地端口、多快」。
public struct APISnapshot: nonisolated Codable, Sendable {
    public var overall: String
    public var overallLabel: String
    public var summary: String
    public var health: [String]
    public var service: APIService
    public var counts: APICounts
    public var subscriptions: [APISubscription]
    public var nodes: [APINode]
    public var output: APIOutput
    public var naming: APINaming
    public var autoUpdatePaused: Bool
    public var nextUpdateAt: Date?
    public var generatedAt: Date?

    public nonisolated init(state: AppViewState, subscriptionServing: Bool, subscriptionError: String?) {
        overall = state.overall.rawValue
        overallLabel = state.overall.label
        summary = state.menuBarSummary
        health = state.healthMessages
        service = APIService(state: state)
        counts = APICounts(state: state)
        subscriptions = state.subscriptions.map(APISubscription.init)
        // 端口来自快照里现算的映射，和即将写进 sing-box 配置的编号同源。
        let ports = Dictionary(state.mappedNodes.map { ($0.node.id, $0.localPort) },
                               uniquingKeysWith: { first, _ in first })
        let sourceNames = Dictionary(state.subscriptions.map { ($0.id, $0.name) },
                                     uniquingKeysWith: { first, _ in first })
        // 输出名同样整批算一次：逐个节点现算的话，名字里的序号和重名补号都算不对。
        let outputNames = state.nodeNaming.namesByNodeID(for: state.mappedNodes)
        nodes = state.mergedNodes.map {
            APINode(node: $0, localPort: ports[$0.id], outputName: outputNames[$0.id], sourceNames: sourceNames)
        }
        output = APIOutput(settings: state.settings, serving: subscriptionServing, error: subscriptionError)
        naming = APINaming(state: state)
        autoUpdatePaused = state.autoUpdatePaused
        nextUpdateAt = state.nextUpdateDate
        generatedAt = state.generatedAt
    }
}

public struct APIService: nonisolated Codable, Sendable {
    public var running: Bool
    public var label: String
    public var failureReason: String?
    public var launchAgentLabel: String

    public nonisolated init(state: AppViewState) {
        running = state.serviceState.isRunning
        label = state.serviceState.label
        failureReason = state.serviceState.failureReason
        launchAgentLabel = state.settings.launchAgentLabel
    }
}

public struct APICounts: nonisolated Codable, Sendable {
    public var subscriptions: Int
    public var enabledSubscriptions: Int
    public var failedSubscriptions: Int
    public var nodes: Int
    public var enabledNodes: Int
    public var rawNodes: Int
    public var deduplicated: Int
    public var tested: Int
    public var failedLatency: Int

    public nonisolated init(state: AppViewState) {
        subscriptions = state.subscriptions.count
        enabledSubscriptions = state.enabledSubscriptionCount
        failedSubscriptions = state.failedSubscriptionCount
        nodes = state.mergedNodes.count
        enabledNodes = state.enabledNodes.count
        rawNodes = state.rawNodeCount
        deduplicated = state.deduplicatedCount
        tested = state.testedNodeCount
        failedLatency = state.failedLatencyCount
    }
}

public struct APISubscription: nonisolated Codable, Sendable {
    public var id: String
    public var name: String
    public var note: String
    public var enabled: Bool
    public var status: String
    public var statusLabel: String
    public var lastError: String?
    public var updatedAt: Date?
    public var updateIntervalHours: Int
    public var nodeCount: Int
    /// 此订阅实际包含的上游协议，用于 Web 订阅列表筛选。
    public var protocols: [String]
    /// 这条订阅自己的节点名模板；没有覆盖时该键不出现，表示跟随全局。
    public var nodeNameTemplate: String?

    public nonisolated init(_ record: SubscriptionRecord) {
        id = record.id.uuidString
        name = record.name
        note = record.note
        enabled = record.isEnabled
        status = record.status.rawValue
        statusLabel = record.status.label
        lastError = record.lastError
        updatedAt = record.updatedAt
        updateIntervalHours = record.updateIntervalHours
        nodeCount = record.nodes.count
        protocols = Set(record.nodes.map { $0.protocolType.rawValue }).sorted()
        nodeNameTemplate = record.nodeNameTemplate
    }
}

public struct APINode: nonisolated Codable, Sendable {
    public var id: String
    public var name: String
    /// 只给出主机名，不给 VLESS 凭据。
    public var server: String
    /// 上游协议（与 RouteBar 在本机暴露的 SOCKS5 相区别）。
    public var protocolLabel: String
    public var enabled: Bool
    /// 未启用的节点没有本地端口。
    public var localPort: Int?
    /// 由命名模板拼出来的节点名。未启用的节点不输出，因此为空。
    public var outputName: String?
    public var latencyMilliseconds: Int?
    public var latencyOutcome: String?
    public var latencyLabel: String?
    /// fast / medium / slow / failed / untested，前端据此上色，阈值不在网页里复写一遍。
    public var band: String
    public var measuredAt: Date?
    public var sources: [String]

    public nonisolated init(node: ProxyNode, localPort: Int?, outputName: String?, sourceNames: [UUID: String]) {
        id = node.id
        name = node.name
        server = node.server
        protocolLabel = node.protocolLabel
        enabled = node.isEnabled
        self.localPort = localPort
        self.outputName = outputName
        latencyMilliseconds = node.latency?.milliseconds
        latencyOutcome = node.latency?.outcome.rawValue
        latencyLabel = node.latency?.outcome.label
        band = switch LatencyClassification.band(for: node.latency) {
        case .untested: "untested"
        case .failed: "failed"
        case .fast: "fast"
        case .medium: "medium"
        case .slow: "slow"
        }
        measuredAt = node.latency?.measuredAt
        sources = node.sourceIDs.compactMap { sourceNames[$0] }
    }
}

/// 本地订阅服务当前是否可用。本机端口与它无关，那批端口由 sing-box 直接提供。
public struct APIOutput: nonisolated Codable, Sendable {
    public var subscriptionURL: String
    public var subscriptionPort: Int
    public var serving: Bool
    public var error: String?
    /// 可直接粘进 Surge 的策略组行，省得用户自己拼。
    public var surgePolicyLine: String

    public nonisolated init(settings: RouteBarSettings, serving: Bool, error: String?) {
        subscriptionURL = settings.subscriptionURL
        subscriptionPort = settings.subscriptionPort
        self.serving = serving
        self.error = error
        surgePolicyLine = settings.surgePolicyGroupLine
    }
}

/// 节点命名规则：全局模板、可用占位符，以及按当前节点算出来的示例。
///
/// 占位符说明和示例都由服务端给，网页不自己再写一份——两边各写一遍，改了模板语法
/// 就会出现「说明里有、实际不认」的占位符。
public struct APINaming: nonisolated Codable, Sendable {
    public var template: String
    public var defaultTemplate: String
    public var placeholders: [APINamingPlaceholder]
    /// 前两个节点按当前模板会叫什么。没有节点时是造出来的示例。
    public var preview: [String]

    public nonisolated init(state: AppViewState) {
        template = state.settings.nodeNameTemplate
        defaultTemplate = NodeNaming.defaultTemplate
        placeholders = NodeNaming.placeholders.map { APINamingPlaceholder(token: $0.token, summary: $0.summary) }
        preview = NodeNaming.preview(template: state.settings.nodeNameTemplate,
                                     subscriptions: state.subscriptions,
                                     mapped: state.mappedNodes)
    }
}

/// `POST /api/naming/preview` 的响应：按传进来的模板试跑，**不保存**。
public struct APINamingPreview: nonisolated Codable, Sendable {
    public var template: String
    public var rows: [APINamingPreviewRow]
    /// 一个启用节点都没有，下面这些是造出来的示例。
    public var isSample: Bool

    public nonisolated init(state: AppViewState, template: String) {
        self.template = NodeNaming.normalized(template)
        let result = NodeNaming.previewRows(template: template,
                                            subscriptions: state.subscriptions,
                                            mapped: state.mappedNodes)
        rows = result.rows.map {
            APINamingPreviewRow(name: $0.originalName, outputName: $0.outputName, localPort: $0.localPort)
        }
        isSample = result.isSample
    }
}

public struct APINamingPreviewRow: nonisolated Codable, Sendable {
    public var name: String
    public var outputName: String
    public var localPort: Int

    public nonisolated init(name: String, outputName: String, localPort: Int) {
        self.name = name
        self.outputName = outputName
        self.localPort = localPort
    }
}

public struct APINamingPlaceholder: nonisolated Codable, Sendable {
    public var token: String
    public var summary: String

    public nonisolated init(token: String, summary: String) {
        self.token = token
        self.summary = summary
    }
}

// MARK: - 请求体

public struct APISubscriptionInput: nonisolated Codable, Sendable {
    public var id: String?
    public var name: String
    /// 新建时必填；编辑时留空表示「保持原地址不变」。
    public var url: String?
    public var note: String?
    public var intervalHours: Int?
    /// 这条订阅的节点名模板。**键缺失表示不改动，空串表示清掉、跟随全局**——
    /// 与 `url` 的「空 = 不改」不同，因为清空模板是个用户会真的想做的操作。
    public var nodeNameTemplate: String?

    public nonisolated init(id: String? = nil, name: String, url: String? = nil,
                            note: String? = nil, intervalHours: Int? = nil,
                            nodeNameTemplate: String? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.note = note
        self.intervalHours = intervalHours
        self.nodeNameTemplate = nodeNameTemplate
    }
}

/// `POST /api/naming` 的请求体：全局节点名模板。
public struct APINamingInput: nonisolated Codable, Sendable {
    public var template: String

    public nonisolated init(template: String) {
        self.template = template
    }
}

public struct APIEnabledInput: nonisolated Codable, Sendable {
    public var enabled: Bool

    public nonisolated init(enabled: Bool) {
        self.enabled = enabled
    }
}

public struct APILogs: nonisolated Codable, Sendable {
    public var singBoxStandard: String
    public var singBoxError: String
    public var runtime: [String]

    public nonisolated init(singBoxStandard: String, singBoxError: String, runtime: [String]) {
        self.singBoxStandard = singBoxStandard
        self.singBoxError = singBoxError
        self.runtime = runtime
    }
}

/// API 的 JSON 编解码约定：日期一律 ISO 8601，键名保持驼峰。
///
/// **可选字段为 nil 时整个键会被省略，而不是编成 `null`**（`JSONEncoder` 的默认行为）。
/// 消费方取 `localPort`、`latencyMilliseconds`、`measuredAt` 这类字段时必须按「键可能不存在」
/// 处理——未启用的节点没有本地端口，未测速的节点没有延迟。
public enum APICoding {
    public nonisolated static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public nonisolated static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
