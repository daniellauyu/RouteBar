import Foundation

/// 一次生成的产物：端口映射、sing-box 配置、Surge [Proxy] 段。
public struct GeneratedConfiguration: Sendable {
    public let nodes: [PortMappedNode]
    public let singBoxJSON: Data
    public let surgeProxySection: String

    public nonisolated init(nodes: [PortMappedNode], singBoxJSON: Data, surgeProxySection: String) {
        self.nodes = nodes
        self.singBoxJSON = singBoxJSON
        self.surgeProxySection = surgeProxySection
    }
}

/// 把启用节点编译成「一节点一本地端口」的 sing-box 配置，并给出对应的 Surge 代理段。
///
/// 为什么一个节点开一个入站而不是用 sing-box 自己的选择器：分流决策留在 Surge 里做。
/// Surge 看到的是一组普通 SOCKS5 代理，规则、策略组、测速都用它原生那一套；
/// sing-box 只负责把某个本地端口的流量按 Reality 送出去，两边职责不重叠。
public enum ConfigurationGenerator {
    public nonisolated static func generate(nodes: [ProxyNode], startingPort: Int = 7701) throws -> GeneratedConfiguration {
        let enabled = NodeCatalog.merge(nodes.filter(\.isEnabled))
        let mapped = enabled.enumerated().map { PortMappedNode(node: $0.element, localPort: startingPort + $0.offset) }

        let inbounds: [[String: Any]] = mapped.enumerated().map { index, item in
            ["type": "mixed", "tag": tag("in", index), "listen": "127.0.0.1",
             "listen_port": item.localPort, "set_system_proxy": false]
        }
        let outbounds: [[String: Any]] = mapped.enumerated().map { index, item in
            let node = item.node
            return [
                "type": "vless", "tag": tag("out", index), "server": node.server,
                "server_port": node.serverPort, "uuid": node.uuid, "flow": node.flow,
                "tls": [
                    "enabled": true, "server_name": node.serverName,
                    "reality": ["enabled": true, "public_key": node.publicKey, "short_id": node.shortID],
                    "utls": ["enabled": true, "fingerprint": node.fingerprint],
                ],
            ]
        }
        // 入站与出站一一绑定：第 N 个端口只走第 N 个节点，绝不串台。
        let rules: [[String: Any]] = mapped.indices.map { index in
            ["inbound": [tag("in", index)], "action": "route", "outbound": tag("out", index),
             "udp_disable_domain_unmapping": true]
        }
        let document: [String: Any] = [
            "log": ["level": "info", "timestamp": true],
            "inbounds": inbounds,
            "outbounds": outbounds,
            "route": ["rules": rules],
        ]
        let json = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        let proxyLines = mapped.enumerated().map { index, item in
            "\(surgeName(index, item.node.name)) = socks5, 127.0.0.1, \(item.localPort)"
        }
        return GeneratedConfiguration(nodes: mapped, singBoxJSON: json,
                                      surgeProxySection: "[Proxy]\n" + proxyLines.joined(separator: "\n") + "\n")
    }

    private nonisolated static func tag(_ prefix: String, _ index: Int) -> String {
        "\(prefix)-routebar-\(String(format: "%02d", index + 1))"
    }

    /// Surge 代理名。
    ///
    /// 逗号、等号、引号和换行在 Surge 配置里是语法字符，节点名里带这些会把整行拆坏，
    /// 因此一律替换成空格。前缀编号保证同名节点不会互相覆盖。
    private nonisolated static func surgeName(_ index: Int, _ name: String) -> String {
        let safe = name.replacingOccurrences(of: "[,=\"'\\r\\n]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return "RouteBar \(String(format: "%02d", index + 1)) - \(safe)"
    }
}
