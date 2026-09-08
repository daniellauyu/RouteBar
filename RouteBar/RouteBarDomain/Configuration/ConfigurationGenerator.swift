import Foundation

/// 一次生成的产物：端口映射、sing-box 配置、Surge [Proxy] 段。
public struct GeneratedConfiguration: Sendable {
    public let nodes: [PortMappedNode]
    public let singBoxJSON: Data
    public let surgeProxySection: String
    /// 这一批代理在 Surge 里叫什么，与 `surgeProxySection` 的每一行一一对应。
    ///
    /// 单独带出来是因为策略组那一行要列出全部名字。原先是从生成的文本里挑
    /// `RouteBar ` 开头的行反推——名字可配置之后，这个前缀不再成立。
    public let policyNames: [String]

    public nonisolated init(nodes: [PortMappedNode], singBoxJSON: Data,
                            surgeProxySection: String, policyNames: [String]) {
        self.nodes = nodes
        self.singBoxJSON = singBoxJSON
        self.surgeProxySection = surgeProxySection
        self.policyNames = policyNames
    }

    /// 供 Surge `policy-path=` 拉取的策略列表。
    ///
    /// 与 `[Proxy]` 段的唯一区别就是**没有段头**——这一点是照着 sub.store 实际返回的内容
    /// 确认的：外部策略集就是一串裸的 `名称 = 协议, 主机, 端口, …`，带上段头 Surge 反而解析不了。
    public nonisolated var surgePolicyList: String {
        surgeProxySection
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}

/// 把启用节点编译成「一节点一本地端口」的 sing-box 配置，并给出对应的 Surge 代理段。
///
/// 为什么一个节点开一个入站而不是用 sing-box 自己的选择器：分流决策留在 Surge 里做。
/// Surge 看到的是一组普通 SOCKS5 代理，规则、策略组、测速都用它原生那一套；
/// sing-box 只负责把某个本地端口的流量按节点自己的上游协议送出去，两边职责不重叠。
public enum ConfigurationGenerator {
    /// 只算「哪个节点占哪个本地端口」，不生成配置文档。
    ///
    /// 界面（节点列表、详情栏）要的只是端口号，而 `generate` 里最贵的一步是把整份
    /// sing-box 配置做 JSONSerialization——实测 51 个节点 1.3ms、500 个节点 12ms。
    /// 状态快照每次操作都要重算端口，走 `generate` 等于每次都白序列化一份配置。
    ///
    /// `generate` 复用这个方法，两条路径的编号规则因此不可能分叉——否则界面显示的端口
    /// 会和真正写进配置的对不上，而这种错位极难发现。
    public nonisolated static func portMapping(nodes: [ProxyNode], startingPort: Int = 7701) -> [PortMappedNode] {
        NodeCatalog.merge(nodes.filter(\.isEnabled))
            .enumerated()
            .map { PortMappedNode(node: $0.element, localPort: startingPort + $0.offset) }
    }

    public nonisolated static func generate(nodes: [ProxyNode],
                                            startingPort: Int = 7701,
                                            naming: NodeNaming = .default) throws -> GeneratedConfiguration {
        let mapped = portMapping(nodes: nodes, startingPort: startingPort)

        let inbounds: [[String: Any]] = mapped.enumerated().map { index, item in
            ["type": "mixed", "tag": tag("in", index), "listen": "127.0.0.1",
             "listen_port": item.localPort, "set_system_proxy": false]
        }
        let outbounds = mapped.enumerated().map { index, item in
            outbound(for: item.node, tag: tag("out", index))
        }
        // 入站与出站一一绑定：第 N 个端口只走第 N 个节点，绝不串台。
        let rules: [[String: Any]] = mapped.indices.map { index in
            ["inbound": [tag("in", index)], "action": "route", "outbound": tag("out", index),
             "udp_disable_domain_unmapping": true]
        }
        // 级别 `warn` 而不是 `info`。
        //
        // `info` 会给**每一条出站连接**打一行。实测一台日常使用的机器上，35 天攒出
        // 65 MB / 43 万行，其中 95% 是 `outbound connection to ...`——而 sing-box 把所有
        // 级别都写进 stderr，于是 RouteBar 那个叫「错误日志」的文件里全是这种噪声，
        // 真正的报错反而挑不出来。这些日志没有轮转，只会一直涨。
        //
        // 连接级别的记录不是没价值，但「哪条流量走了哪个节点」在节点页看端口就知道，
        // 代价却是把唯一一份诊断文件淹掉。握手失败、配置错误、端口占用这些真正需要
        // 排查的东西都是 warn 及以上，一条不会丢。
        let document: [String: Any] = [
            "log": ["level": "warn", "timestamp": true],
            "inbounds": inbounds,
            "outbounds": outbounds,
            "route": ["rules": rules],
        ]
        let json = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        let names = naming.names(for: mapped)
        return GeneratedConfiguration(nodes: mapped, singBoxJSON: json,
                                      surgeProxySection: "[Proxy]\n" + policyLines(names: names, mapped: mapped),
                                      policyNames: names)
    }

    /// 裸策略行（无 `[Proxy]` 段头），本地订阅服务直接返回这一份。
    ///
    /// 单独拎出来是为了让「写进配置文件的 `[Proxy]` 段」和「订阅地址返回的列表」同源。
    /// 各写一遍的话，两种输出方式并用（`.both`）时 Surge 会看到两套名字不同的同一批节点，
    /// 而这种错位只有逐行比对才看得出来。
    ///
    /// `naming` 也必须两边同源：本地订阅服务是按请求现算的，传了不一样的命名规则，
    /// 同一个端口在两种输出方式下会有两个名字。
    public nonisolated static func surgePolicyLines(_ mapped: [PortMappedNode],
                                                    naming: NodeNaming = .default) -> String {
        policyLines(names: naming.names(for: mapped), mapped: mapped)
    }

    private nonisolated static func policyLines(names: [String], mapped: [PortMappedNode]) -> String {
        zip(names, mapped)
            .map { "\($0) = socks5, 127.0.0.1, \($1.localPort)" }
            .joined(separator: "\n") + "\n"
    }

    private nonisolated static func outbound(for node: ProxyNode, tag: String) -> [String: Any] {
        var result: [String: Any] = [
            "type": node.protocolType == .shadowsocks ? "shadowsocks" : node.protocolType.rawValue,
            "tag": tag,
            "server": node.server,
            "server_port": node.serverPort,
        ]

        switch node.protocolType {
        case .vless:
            result["uuid"] = node.uuid
            if !node.flow.isEmpty { result["flow"] = node.flow }
        case .vmess:
            result["uuid"] = node.uuid
            result["security"] = node.security
            result["alter_id"] = node.alterID
        case .trojan:
            result["password"] = node.password
        case .shadowsocks:
            result["method"] = node.method
            result["password"] = node.password
            if !node.plugin.isEmpty { result["plugin"] = node.plugin }
            if !node.pluginOptions.isEmpty { result["plugin_opts"] = node.pluginOptions }
        }

        if node.protocolType != .shadowsocks, node.tlsEnabled {
            var tls: [String: Any] = ["enabled": true, "server_name": node.serverName]
            if node.allowInsecure { tls["insecure"] = true }
            if !node.publicKey.isEmpty {
                tls["reality"] = ["enabled": true, "public_key": node.publicKey, "short_id": node.shortID]
            }
            if !node.fingerprint.isEmpty {
                tls["utls"] = ["enabled": true, "fingerprint": node.fingerprint]
            }
            result["tls"] = tls
        }

        if node.protocolType != .shadowsocks, let transport = transport(for: node) {
            result["transport"] = transport
        }
        return result
    }

    private nonisolated static func transport(for node: ProxyNode) -> [String: Any]? {
        switch node.transport.lowercased() {
        case "", "tcp", "none":
            return nil
        case "ws", "websocket":
            var result: [String: Any] = ["type": "ws"]
            if !node.path.isEmpty { result["path"] = node.path }
            if !node.transportHost.isEmpty { result["headers"] = ["Host": node.transportHost] }
            return result
        case "grpc":
            var result: [String: Any] = ["type": "grpc"]
            if !node.serviceName.isEmpty { result["service_name"] = node.serviceName }
            return result
        case "http", "h2":
            var result: [String: Any] = ["type": "http"]
            if !node.path.isEmpty { result["path"] = node.path }
            if !node.transportHost.isEmpty { result["host"] = [node.transportHost] }
            return result
        default:
            // 保留节点；未知传输不写进配置，避免生成 sing-box 不认识的 transport 类型。
            return nil
        }
    }

    /// sing-box 的内部标签。
    ///
    /// 与用户可配置的 Surge 代理名无关，也不该跟着它走：这两个 tag 只要求唯一且稳定，
    /// 入站与出站靠它们一一绑定，掺进用户输入只会引入重名和非法字符的风险。
    private nonisolated static func tag(_ prefix: String, _ index: Int) -> String {
        "\(prefix)-routebar-\(String(format: "%02d", index + 1))"
    }
}
