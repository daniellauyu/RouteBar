import Foundation

public enum ConfigurationGenerator {
    public static func generate(nodes: [ProxyNode], startingPort: Int = 7701) throws -> GeneratedConfiguration {
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

    private static func tag(_ prefix: String, _ index: Int) -> String {
        "\(prefix)-routebar-\(String(format: "%02d", index + 1))"
    }

    private static func surgeName(_ index: Int, _ name: String) -> String {
        let safe = name.replacingOccurrences(of: "[,=\"'\\r\\n]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return "RouteBar \(String(format: "%02d", index + 1)) - \(safe)"
    }
}

public enum SurgeProfileUpdater {
    public static func update(_ profile: String, with generated: GeneratedConfiguration) throws -> String {
        guard let proxyStart = profile.range(of: "[Proxy]"),
              let groupStart = profile.range(of: "[Proxy Group]", range: proxyStart.upperBound..<profile.endIndex) else {
            throw UpdateError.missingSection
        }
        var result = profile
        result.replaceSubrange(proxyStart.lowerBound..<groupStart.lowerBound, with: generated.surgeProxySection + "\n")
        let names = generated.surgeProxySection.components(separatedBy: .newlines)
            .filter { $0.hasPrefix("RouteBar ") }
            .compactMap { $0.components(separatedBy: " = ").first }
            .map { "\"\($0)\"" }.joined(separator: ", ")
        let regex = try NSRegularExpression(pattern: #"(?m)^sing-box 节点\s*=.*$"#)
        if let match = regex.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)),
           let range = Range(match.range, in: result) {
            result.replaceSubrange(range, with: "sing-box 节点 = select, \(names)")
        } else if let groups = result.range(of: "[Proxy Group]\n") {
            result.insert(contentsOf: "sing-box 节点 = select, \(names)\n", at: groups.upperBound)
        }
        return result
    }

    public enum UpdateError: LocalizedError {
        case missingSection
        public var errorDescription: String? { "Surge 配置缺少 [Proxy] 或 [Proxy Group] 段" }
    }
}
