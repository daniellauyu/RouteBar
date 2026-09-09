import Foundation

public enum ProxyProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
    case vless
    case shadowsocks = "ss"
    case trojan
    case vmess
    case hysteria2

    public nonisolated var id: String { rawValue }

    public nonisolated var label: String {
        switch self {
        case .vless: "VLESS"
        case .shadowsocks: "SS"
        case .trojan: "Trojan"
        case .vmess: "VMess"
        case .hysteria2: "Hysteria2"
        }
    }
}

/// 一个上游代理节点。
///
/// `id` 不是随机 UUID，而是由协议和连接参数哈希得到的稳定指纹
/// （见 `SubscriptionParser`）。机场经常换节点名、换排序，只有连接参数才是同一个节点的身份；
/// 用指纹做主键，多个订阅里的同一节点才能被识别成一个，刷新订阅后启用状态和测速结果也才跟得住。
public struct ProxyNode: Codable, Hashable, Identifiable, Sendable {
    /// 订阅中的原始条目身份。与 `id`（连接指纹）分开，允许同一出口在一个或多个订阅中
    /// 出现多次，并让每一条记录都能独立显示和开关。
    public var entryID: String
    public var id: String
    public var name: String
    public var server: String
    public var serverPort: Int
    public var protocolType: ProxyProtocol
    public var uuid: String
    public var password: String
    public var method: String
    public var alterID: Int
    public var security: String
    public var transport: String
    public var transportHost: String
    public var path: String
    public var serviceName: String
    public var tlsEnabled: Bool
    public var allowInsecure: Bool
    public var plugin: String
    public var pluginOptions: String
    public var obfuscation: String
    public var obfuscationPassword: String
    public var upMbps: Int
    public var downMbps: Int
    public var flow: String
    public var serverName: String
    public var publicKey: String
    public var shortID: String
    public var fingerprint: String
    /// 提供该节点的订阅（同一节点可能来自多个订阅）。
    public var sourceIDs: [UUID]
    public var isEnabled: Bool
    public var latency: LatencyRecord?

    public nonisolated init(id: String, entryID: String = "", name: String, server: String, serverPort: Int,
                            protocolType: ProxyProtocol = .vless, uuid: String,
                            password: String = "", method: String = "", alterID: Int = 0,
                            security: String = "auto", transport: String = "tcp",
                            transportHost: String = "", path: String = "", serviceName: String = "",
                            tlsEnabled: Bool = false, allowInsecure: Bool = false,
                            plugin: String = "", pluginOptions: String = "",
                            obfuscation: String = "", obfuscationPassword: String = "",
                            upMbps: Int = 0, downMbps: Int = 0,
                            flow: String, serverName: String, publicKey: String, shortID: String,
                            fingerprint: String, sourceIDs: [UUID], isEnabled: Bool, latency: LatencyRecord? = nil) {
        self.id = id
        self.entryID = entryID.isEmpty ? id : entryID
        self.name = name
        self.server = server
        self.serverPort = serverPort
        self.protocolType = protocolType
        self.uuid = uuid
        self.password = password
        self.method = method
        self.alterID = alterID
        self.security = security
        self.transport = transport
        self.transportHost = transportHost
        self.path = path
        self.serviceName = serviceName
        self.tlsEnabled = tlsEnabled
        self.allowInsecure = allowInsecure
        self.plugin = plugin
        self.pluginOptions = pluginOptions
        self.obfuscation = obfuscation
        self.obfuscationPassword = obfuscationPassword
        self.upMbps = upMbps
        self.downMbps = downMbps
        self.flow = flow
        self.serverName = serverName
        self.publicKey = publicKey
        self.shortID = shortID
        self.fingerprint = fingerprint
        self.sourceIDs = sourceIDs
        self.isEnabled = isEnabled
        self.latency = latency
    }

    /// 节点在**上游**用的协议，与 RouteBar 在本机暴露出的 SOCKS5 相区别。
    ///
    /// 列表里只看得到本地端口，那是 RouteBar 造出来的壳；真正决定这个节点能不能连通的是
    /// Reality 是 VLESS 的安全层，因此保留在标签里，筛选时仍归到 VLESS。
    public nonisolated var protocolLabel: String {
        protocolType == .vless && !publicKey.isEmpty ? "VLESS-Reality" : protocolType.label
    }

    private enum CodingKeys: String, CodingKey {
        case entryID, id, name, server, serverPort, protocolType, uuid, password, method, alterID, security
        case transport, transportHost, path, serviceName, tlsEnabled, allowInsecure, plugin, pluginOptions
        case obfuscation, obfuscationPassword, upMbps, downMbps
        case flow, serverName, publicKey, shortID, fingerprint, sourceIDs, isEnabled, latency
    }

    /// 新增协议字段后仍能读取旧版本只含 VLESS Reality 字段的 state.json。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        entryID = try container.decodeIfPresent(String.self, forKey: .entryID) ?? id
        name = try container.decode(String.self, forKey: .name)
        server = try container.decode(String.self, forKey: .server)
        serverPort = try container.decode(Int.self, forKey: .serverPort)
        protocolType = try container.decodeIfPresent(ProxyProtocol.self, forKey: .protocolType) ?? .vless
        uuid = try container.decodeIfPresent(String.self, forKey: .uuid) ?? ""
        password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
        method = try container.decodeIfPresent(String.self, forKey: .method) ?? ""
        alterID = try container.decodeIfPresent(Int.self, forKey: .alterID) ?? 0
        security = try container.decodeIfPresent(String.self, forKey: .security) ?? "auto"
        transport = try container.decodeIfPresent(String.self, forKey: .transport) ?? "tcp"
        transportHost = try container.decodeIfPresent(String.self, forKey: .transportHost) ?? ""
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        serviceName = try container.decodeIfPresent(String.self, forKey: .serviceName) ?? ""
        tlsEnabled = try container.decodeIfPresent(Bool.self, forKey: .tlsEnabled)
            ?? !(try container.decodeIfPresent(String.self, forKey: .publicKey) ?? "").isEmpty
        allowInsecure = try container.decodeIfPresent(Bool.self, forKey: .allowInsecure) ?? false
        plugin = try container.decodeIfPresent(String.self, forKey: .plugin) ?? ""
        pluginOptions = try container.decodeIfPresent(String.self, forKey: .pluginOptions) ?? ""
        obfuscation = try container.decodeIfPresent(String.self, forKey: .obfuscation) ?? ""
        obfuscationPassword = try container.decodeIfPresent(String.self, forKey: .obfuscationPassword) ?? ""
        upMbps = try container.decodeIfPresent(Int.self, forKey: .upMbps) ?? 0
        downMbps = try container.decodeIfPresent(Int.self, forKey: .downMbps) ?? 0
        flow = try container.decodeIfPresent(String.self, forKey: .flow) ?? ""
        serverName = try container.decodeIfPresent(String.self, forKey: .serverName) ?? server
        publicKey = try container.decodeIfPresent(String.self, forKey: .publicKey) ?? ""
        shortID = try container.decodeIfPresent(String.self, forKey: .shortID) ?? ""
        fingerprint = try container.decodeIfPresent(String.self, forKey: .fingerprint) ?? "chrome"
        sourceIDs = try container.decodeIfPresent([UUID].self, forKey: .sourceIDs) ?? []
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        latency = try container.decodeIfPresent(LatencyRecord.self, forKey: .latency)
    }
}

/// 节点合并与状态承接。
public enum NodeCatalog {
    /// 为订阅中的每条原始记录补上稳定身份。旧状态里的 entryID 等于连接指纹，加载时也会迁移。
    public nonisolated static func assignEntryIDs(_ nodes: [ProxyNode], sourceID: UUID) -> [ProxyNode] {
        var occurrences: [String: Int] = [:]
        return nodes.map { node in
            var node = node
            let occurrence = occurrences[node.id, default: 0]
            occurrences[node.id] = occurrence + 1
            if node.entryID == node.id {
                node.entryID = "\(sourceID.uuidString.lowercased())|\(node.id)|\(occurrence)"
            }
            return node
        }
    }

    /// 按指纹去重，合并来源并保留任一来源的启用状态。
    public nonisolated static func merge(_ nodes: [ProxyNode]) -> [ProxyNode] {
        var merged: [String: ProxyNode] = [:]
        for node in nodes {
            if var existing = merged[node.id] {
                existing.sourceIDs = Array(Set(existing.sourceIDs + node.sourceIDs))
                    .sorted { $0.uuidString < $1.uuidString }
                existing.isEnabled = existing.isEnabled || node.isEnabled
                merged[node.id] = existing
            } else {
                merged[node.id] = node
            }
        }
        return merged.values.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    /// 把上一轮的用户状态（启用与否、测速结果）搬到刚拉取的节点上。
    ///
    /// 订阅刷新会整份替换节点列表；不搬运的话，用户手动禁用的节点会在每次自动更新后
    /// 悄悄复活，测速结果也会全部清零。
    public nonisolated static func carryPersistedState(from previous: [ProxyNode], to refreshed: [ProxyNode]) -> [ProxyNode] {
        let oldByEntryID = Dictionary(previous.map { ($0.entryID, $0) }, uniquingKeysWith: { first, _ in first })
        let oldByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return refreshed.map { node in
            var node = node
            // entryID 在同一订阅的刷新之间稳定。按连接指纹回退仅用于迁移旧版 state.json。
            if let old = oldByEntryID[node.entryID] ?? oldByID[node.id] {
                node.isEnabled = old.isEnabled
                node.latency = old.latency
            }
            return node
        }
    }
}

/// 节点与它在本机 sing-box 上的入站端口。
public struct PortMappedNode: Sendable, Identifiable {
    public let node: ProxyNode
    public let localPort: Int

    public nonisolated init(node: ProxyNode, localPort: Int) {
        self.node = node
        self.localPort = localPort
    }

    public nonisolated var id: String { node.entryID }
}

public enum LatencyOutcome: String, Codable, Sendable {
    case success, timeout, connectionFailed, httpFailed

    public nonisolated var label: String {
        switch self {
        case .success: "可用"
        case .timeout: "超时"
        case .connectionFailed: "连接失败"
        case .httpFailed: "响应异常"
        }
    }
}

public struct LatencyRecord: Codable, Hashable, Sendable {
    public var outcome: LatencyOutcome
    public var milliseconds: Int?
    public var measuredAt: Date

    public nonisolated init(outcome: LatencyOutcome, milliseconds: Int?, measuredAt: Date = .now) {
        self.outcome = outcome
        self.milliseconds = milliseconds
        self.measuredAt = measuredAt
    }

    public nonisolated func isStale(at date: Date = .now, maximumAge: TimeInterval = 600) -> Bool {
        date.timeIntervalSince(measuredAt) > maximumAge
    }
}

/// RouteBar 测的是「Surge → 本地 sing-box → 上游节点 → 测试站点」的端到端延迟，
/// 天然包含多段握手与往返，不能套用直连节点常见的 100/200 ms 阈值。
public enum LatencyBand: Sendable, Equatable {
    case untested, failed, fast, medium, slow
}

public enum LatencyClassification {
    public nonisolated static var fastUpperBound: Int { 600 }
    public nonisolated static var mediumUpperBound: Int { 1_000 }

    public nonisolated static func band(for latency: LatencyRecord?) -> LatencyBand {
        guard let latency else { return .untested }
        guard latency.outcome == .success, let milliseconds = latency.milliseconds else { return .failed }
        if milliseconds < fastUpperBound { return .fast }
        if milliseconds <= mediumUpperBound { return .medium }
        return .slow
    }
}
