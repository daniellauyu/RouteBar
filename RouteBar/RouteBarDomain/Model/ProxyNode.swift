import Foundation

/// 一个 VLESS Reality 节点。
///
/// `id` 不是随机 UUID，而是由「服务器 + 端口 + UUID + 公钥 + shortID」哈希得到的稳定指纹
/// （见 `VLESSParser`）。机场经常换节点名、换排序，只有连接参数才是同一个节点的身份；
/// 用指纹做主键，多个订阅里的同一节点才能被识别成一个，刷新订阅后启用状态和测速结果也才跟得住。
public struct ProxyNode: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var server: String
    public var serverPort: Int
    public var uuid: String
    public var flow: String
    public var serverName: String
    public var publicKey: String
    public var shortID: String
    public var fingerprint: String
    /// 提供该节点的订阅（同一节点可能来自多个订阅）。
    public var sourceIDs: [UUID]
    public var isEnabled: Bool
    public var latency: LatencyRecord?

    public nonisolated init(id: String, name: String, server: String, serverPort: Int, uuid: String,
                            flow: String, serverName: String, publicKey: String, shortID: String,
                            fingerprint: String, sourceIDs: [UUID], isEnabled: Bool, latency: LatencyRecord? = nil) {
        self.id = id
        self.name = name
        self.server = server
        self.serverPort = serverPort
        self.uuid = uuid
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
    /// 上游协议。今天它对每个节点都是同一个值，因为 `VLESSParser` 只认 VLESS Reality 链接——
    /// 订阅里的 ss / trojan / vmess 会被**静默丢弃**。把协议标出来，正是为了让「导入的节点
    /// 比订阅里少」这件事有迹可循，而不是让人以为节点凭空少了。
    public nonisolated var protocolLabel: String {
        publicKey.isEmpty ? "VLESS" : "VLESS-Reality"
    }
}

/// 节点合并与状态承接。
public enum NodeCatalog {
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
        let oldByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return refreshed.map { node in
            var node = node
            if let old = oldByID[node.id] {
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

    public nonisolated var id: String { node.id }
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

/// RouteBar 测的是「Surge → 本地 sing-box → Reality 节点 → 测试站点」的端到端延迟，
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
