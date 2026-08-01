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
/// sing-box 只负责把某个本地端口的流量按 Reality 送出去，两边职责不重叠。
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

    public nonisolated static func generate(nodes: [ProxyNode], startingPort: Int = 7701) throws -> GeneratedConfiguration {
        let mapped = portMapping(nodes: nodes, startingPort: startingPort)

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
        return GeneratedConfiguration(nodes: mapped, singBoxJSON: json,
                                      surgeProxySection: "[Proxy]\n" + surgePolicyLines(mapped))
    }

    /// 裸策略行（无 `[Proxy]` 段头），本地订阅服务直接返回这一份。
    ///
    /// 单独拎出来是为了让「写进配置文件的 `[Proxy]` 段」和「订阅地址返回的列表」同源。
    /// 各写一遍的话，两种输出方式并用（`.both`）时 Surge 会看到两套名字不同的同一批节点，
    /// 而这种错位只有逐行比对才看得出来。
    public nonisolated static func surgePolicyLines(_ mapped: [PortMappedNode]) -> String {
        mapped.enumerated()
            .map { "\(surgeName($0.offset, $0.element.node.name)) = socks5, 127.0.0.1, \($0.element.localPort)" }
            .joined(separator: "\n") + "\n"
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
