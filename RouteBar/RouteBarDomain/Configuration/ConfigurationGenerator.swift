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
        nodes.filter(\.isEnabled)
            .sorted(by: NodeCatalog.precedes)
            .enumerated()
            .map { PortMappedNode(node: $0.element, localPort: startingPort + $0.offset) }
    }

    /// `plan` 传 nil 时按 `naming` 现算。传值是给脚本命名用的：脚本要跑
    /// JavaScriptCore，只能在 Core 层算好再交进来。
    public nonisolated static func generate(nodes: [ProxyNode],
                                            startingPort: Int = 7701,
                                            naming: NodeNaming = .default,
                                            plan: NormalizationPlan? = nil) throws -> GeneratedConfiguration {
        let mapped = portMapping(nodes: nodes, startingPort: startingPort)

        let inbounds: [[String: Any]] = mapped.enumerated().map { index, item in
            ["type": "mixed", "tag": tag("in", index), "listen": "127.0.0.1",
             "listen_port": item.localPort, "set_system_proxy": false]
        }
        let outbounds = try mapped.enumerated().map { index, item in
            try outbound(for: item.node, tag: tag("out", index))
        }
        // 入站与出站一一绑定：第 N 个端口只走第 N 个节点，绝不串台。
        let rules: [[String: Any]] = mapped.indices.map { index in
            ["inbound": [tag("in", index)], "action": "route", "outbound": tag("out", index),
             "udp_disable_domain_unmapping": true]
        }
        // INFO 记录每条经过 RouteBar 的出站连接，供日志页按域名和节点排查。
        // 原始 stderr 文件由日志摄入流程在归档后定期截断，日期归档保留 14 天。
        let document: [String: Any] = [
            "log": ["level": "info", "timestamp": true],
            "inbounds": inbounds,
            "outbounds": outbounds,
            "route": ["rules": rules],
        ]
        let json = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        let plan = plan ?? naming.plan(for: mapped)
        let lines = policyLines(plan: plan, mapped: mapped)
        return GeneratedConfiguration(nodes: mapped, singBoxJSON: json,
                                      surgeProxySection: "[Proxy]\n" + lines.text,
                                      policyNames: lines.names)
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
                                                    naming: NodeNaming = .default,
                                                    plan: NormalizationPlan? = nil) -> String {
        policyLines(plan: plan ?? naming.plan(for: mapped), mapped: mapped).text
    }

    /// 把规划铺成一行行 `名称 = socks5, 127.0.0.1, 端口, udp-relay=true`。
    ///
    /// `udp-relay=true` 不是可选的。Surge 对 SOCKS5 代理**默认不转发 UDP**，不写这一项，
    /// QUIC、游戏、部分视频流的 UDP 流量根本不会进到 sing-box 里——而这种失败是沉默的：
    /// TCP 一切正常，只有依赖 UDP 的那部分变慢或退回明文，看日志也看不出来。
    /// sing-box 这边一直是就绪的：入站是 `mixed`（SOCKS5 支持 UDP ASSOCIATE），
    /// 路由规则上的 `udp_disable_domain_unmapping` 本来就只有 UDP 真流过来才有意义。
    ///
    /// 每一行的名字与端口的绑定由 `plan.lines` 给定，这一层只负责铺成文本——
    /// 同一个端口出现在多行里是合法的（合成的信息入口借的就是别人的连接参数）。
    private nonisolated static func policyLines(plan: NormalizationPlan,
                                                mapped: [PortMappedNode]) -> (text: String, names: [String]) {
        let names = plan.lines.map(\.name)
        let text = plan.lines
            .map { "\($0.name) = socks5, 127.0.0.1, \(mapped[$0.index].localPort), udp-relay=true" }
            .joined(separator: "\n") + "\n"
        return (text, names)
    }

    private nonisolated static func outbound(for node: ProxyNode, tag: String) throws -> [String: Any] {
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
        case .hysteria2:
            result["password"] = node.password
            if node.upMbps > 0 { result["up_mbps"] = node.upMbps }
            if node.downMbps > 0 { result["down_mbps"] = node.downMbps }
            if !node.obfuscation.isEmpty {
                result["obfs"] = ["type": node.obfuscation, "password": node.obfuscationPassword]
            }
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

        if node.protocolType != .shadowsocks && node.protocolType != .hysteria2,
           let transport = try transport(for: node) {
            result["transport"] = transport
        }
        return result
    }

    /// 解析订阅与生成既有缓存配置共用校验，未知传输不能静默变成 TCP。
    public nonisolated static func validateTransport(for node: ProxyNode) throws {
        guard node.protocolType != .shadowsocks && node.protocolType != .hysteria2 else { return }
        _ = try transport(for: node)
    }

    public enum ConfigurationError: LocalizedError, Equatable {
        case unsupportedTransport(nodeName: String, transport: String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedTransport(let name, let transport):
                "节点「\(name)」使用暂不支持的传输方式「\(transport)」，未应用本次配置"
            }
        }
    }

    private nonisolated static func transport(for node: ProxyNode) throws -> [String: Any]? {
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
            throw ConfigurationError.unsupportedTransport(nodeName: node.name, transport: node.transport)
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
