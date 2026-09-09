import CryptoKit
import Foundation

/// 解析常见代理订阅。单条坏链接不会影响同一订阅里的其他节点。
public enum SubscriptionParser {
    public nonisolated static func parseSubscription(_ data: Data, sourceID: UUID) throws -> [ProxyNode] {
        let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let body: String
        if containsSupportedURI(raw) {
            body = raw
        } else if let decoded = decodeBase64(raw) {
            body = String(decoding: decoded, as: UTF8.self)
        } else {
            body = ""
        }

        return NodeCatalog.merge(body.components(separatedBy: .newlines).compactMap {
            parseURI($0, sourceID: sourceID)
        })
    }

    private nonisolated static func containsSupportedURI(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ProxyProtocol.allCases.contains { lower.contains("\($0.rawValue)://") }
            || lower.contains("hy2://")
    }

    private nonisolated static func parseURI(_ line: String, sourceID: UUID) -> ProxyNode? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheme = trimmed.prefix { $0 != ":" }.lowercased()
        return switch scheme {
        case ProxyProtocol.vless.rawValue: parseVLESS(trimmed, sourceID: sourceID)
        case ProxyProtocol.shadowsocks.rawValue: parseShadowsocks(trimmed, sourceID: sourceID)
        case ProxyProtocol.trojan.rawValue: parseTrojan(trimmed, sourceID: sourceID)
        case ProxyProtocol.vmess.rawValue: parseVMess(trimmed, sourceID: sourceID)
        case ProxyProtocol.hysteria2.rawValue, "hy2": parseHysteria2(trimmed, sourceID: sourceID)
        default: nil
        }
    }

    private nonisolated static func parseVLESS(_ uri: String, sourceID: UUID) -> ProxyNode? {
        guard let components = URLComponents(string: uri),
              let server = components.host, let port = components.port,
              let uuid = components.user?.removingPercentEncoding, !uuid.isEmpty else { return nil }
        let values = queryValues(components)
        let security = values["security", default: "none"].lowercased()
        let transport = values["type", default: "tcp"].lowercased()
        let publicKey = values["pbk", default: ""]
        let shortID = values["sid", default: ""]
        // 旧版 Reality/TCP 节点继续使用原指纹，刷新后才能承接启用状态和测速结果。
        let identity = security == "reality" && transport == "tcp"
            ? [server, String(port), uuid, publicKey, shortID].joined(separator: "|")
            : identityString(.vless, server, port, [uuid, security, transport, values["sni", default: ""],
                                                    publicKey, shortID, values["path", default: ""],
                                                    values["serviceName", default: ""]])
        return ProxyNode(
            id: digest(identity), name: displayName(components, fallback: server), server: server,
            serverPort: port, protocolType: .vless, uuid: uuid, security: security,
            transport: transport, transportHost: values["host", default: ""],
            path: values["path", default: ""], serviceName: values["serviceName", default: ""],
            tlsEnabled: security == "tls" || security == "reality",
            allowInsecure: boolean(values["allowInsecure"]),
            flow: values["flow", default: ""], serverName: values["sni", default: server],
            publicKey: publicKey, shortID: shortID, fingerprint: values["fp", default: "chrome"],
            sourceIDs: [sourceID], isEnabled: true)
    }

    private nonisolated static func parseTrojan(_ uri: String, sourceID: UUID) -> ProxyNode? {
        guard let components = URLComponents(string: uri),
              let server = components.host, let port = components.port,
              let password = components.user?.removingPercentEncoding, !password.isEmpty else { return nil }
        let values = queryValues(components)
        let transport = values["type", default: "tcp"].lowercased()
        let security = values["security", default: "tls"].lowercased()
        let identity = identityString(.trojan, server, port, [password, security, transport,
                                                              values["sni", default: ""],
                                                              values["path", default: ""],
                                                              values["serviceName", default: ""]])
        return ProxyNode(
            id: digest(identity), name: displayName(components, fallback: server), server: server,
            serverPort: port, protocolType: .trojan, uuid: "", password: password, security: security,
            transport: transport, transportHost: values["host", default: ""],
            path: values["path", default: ""], serviceName: values["serviceName", default: ""],
            tlsEnabled: security != "none", allowInsecure: boolean(values["allowInsecure"]), flow: "",
            serverName: values["sni", default: server], publicKey: "", shortID: "",
            fingerprint: values["fp", default: "chrome"], sourceIDs: [sourceID], isEnabled: true)
    }

    private nonisolated static func parseShadowsocks(_ uri: String, sourceID: UUID) -> ProxyNode? {
        guard uri.lowercased().hasPrefix("ss://") else { return nil }
        let remainder = String(uri.dropFirst(5))
        let pieces = remainder.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let main = String(pieces[0])
        let name = pieces.count > 1 ? String(pieces[1]).removingPercentEncoding : nil
        let decodedMain: String
        if main.contains("@") {
            decodedMain = main
        } else if let data = decodeBase64(main), let value = String(data: data, encoding: .utf8) {
            decodedMain = value
        } else { return nil }

        guard let at = decodedMain.lastIndex(of: "@") else { return nil }
        var credentials = String(decodedMain[..<at])
        if !credentials.contains(":"), let data = decodeBase64(credentials),
           let decoded = String(data: data, encoding: .utf8) { credentials = decoded }
        credentials = credentials.removingPercentEncoding ?? credentials
        let endpoint = String(decodedMain[decodedMain.index(after: at)...])
        guard let colon = credentials.firstIndex(of: ":") else { return nil }
        let method = String(credentials[..<colon])
        let password = String(credentials[credentials.index(after: colon)...])
        guard !method.isEmpty, !password.isEmpty,
              let endpointComponents = URLComponents(string: "ss://x@\(endpoint)"),
              let server = endpointComponents.host, let port = endpointComponents.port else { return nil }
        let values = queryValues(endpointComponents)
        let pluginParts = values["plugin", default: ""].split(separator: ";", maxSplits: 1,
                                                               omittingEmptySubsequences: false)
        let plugin = pluginParts.first.map(String.init) ?? ""
        let pluginOptions = pluginParts.count > 1 ? String(pluginParts[1]) : values["plugin-opts", default: ""]
        let identity = identityString(.shadowsocks, server, port, [method, password,
                                                                   plugin, pluginOptions])
        return ProxyNode(
            id: digest(identity), name: (name?.isEmpty == false ? name : nil) ?? server,
            server: server, serverPort: port, protocolType: .shadowsocks, uuid: "",
            password: password, method: method, plugin: plugin, pluginOptions: pluginOptions,
            flow: "", serverName: server,
            publicKey: "", shortID: "", fingerprint: "", sourceIDs: [sourceID], isEnabled: true)
    }

    private nonisolated static func parseVMess(_ uri: String, sourceID: UUID) -> ProxyNode? {
        guard uri.lowercased().hasPrefix("vmess://"),
              let data = decodeBase64(String(uri.dropFirst(8))),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let server = string(object["add"]), !server.isEmpty,
              let port = int(object["port"]),
              let uuid = string(object["id"]), !uuid.isEmpty else { return nil }
        let transport = string(object["net"])?.lowercased() ?? "tcp"
        let tlsValue = string(object["tls"])?.lowercased() ?? ""
        let security = string(object["scy"]) ?? "auto"
        let sni = string(object["sni"]) ?? server
        let path = string(object["path"]) ?? ""
        let host = string(object["host"]) ?? ""
        let serviceName = transport == "grpc" ? path : ""
        let identity = identityString(.vmess, server, port, [uuid, security, transport, sni, host, path])
        return ProxyNode(
            id: digest(identity), name: string(object["ps"]) ?? server, server: server,
            serverPort: port, protocolType: .vmess, uuid: uuid,
            alterID: int(object["aid"]) ?? 0, security: security, transport: transport,
            transportHost: host, path: path, serviceName: serviceName,
            tlsEnabled: tlsValue == "tls", allowInsecure: boolean(string(object["allowInsecure"])),
            flow: "", serverName: sni, publicKey: "", shortID: "",
            fingerprint: string(object["fp"]) ?? "chrome", sourceIDs: [sourceID], isEnabled: true)
    }

    private nonisolated static func parseHysteria2(_ uri: String, sourceID: UUID) -> ProxyNode? {
        guard let components = URLComponents(string: uri),
              let server = components.host, let port = components.port,
              let user = components.user?.removingPercentEncoding, !user.isEmpty else { return nil }
        let password: String
        if let suffix = components.password?.removingPercentEncoding, !suffix.isEmpty {
            password = "\(user):\(suffix)"
        } else {
            password = user
        }
        let values = queryValues(components)
        let obfuscation = values["obfs", default: ""]
        let obfuscationPassword = values["obfs-password", default: values["obfsPassword", default: ""]]
        let identity = identityString(.hysteria2, server, port, [password,
                                                                 values["sni", default: ""],
                                                                 obfuscation, obfuscationPassword])
        return ProxyNode(
            id: digest(identity), name: displayName(components, fallback: server), server: server,
            serverPort: port, protocolType: .hysteria2, uuid: "", password: password,
            tlsEnabled: true,
            allowInsecure: boolean(values["insecure"] ?? values["allowInsecure"]),
            obfuscation: obfuscation, obfuscationPassword: obfuscationPassword,
            upMbps: Int(values["upmbps", default: values["up_mbps", default: ""]]) ?? 0,
            downMbps: Int(values["downmbps", default: values["down_mbps", default: ""]]) ?? 0,
            flow: "", serverName: values["sni", default: server], publicKey: "", shortID: "",
            fingerprint: "", sourceIDs: [sourceID], isEnabled: true)
    }

    private nonisolated static func queryValues(_ components: URLComponents) -> [String: String] {
        Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                   uniquingKeysWith: { first, _ in first })
    }

    private nonisolated static func displayName(_ components: URLComponents, fallback: String) -> String {
        let value = components.fragment?.removingPercentEncoding?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value! : fallback
    }

    private nonisolated static func identityString(_ type: ProxyProtocol, _ server: String, _ port: Int,
                                                   _ values: [String]) -> String {
        ([type.rawValue, server, String(port)] + values).joined(separator: "|")
    }

    private nonisolated static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func decodeBase64(_ value: String) -> Data? {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder != 0 { normalized += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: normalized, options: .ignoreUnknownCharacters)
    }

    private nonisolated static func string(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private nonisolated static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private nonisolated static func boolean(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["1", "true", "yes"].contains(value.lowercased())
    }
}

/// 保留旧公开名字，避免已有调用方和测试在升级时中断。
public enum VLESSParser {
    public nonisolated static func parseSubscription(_ data: Data, sourceID: UUID) throws -> [ProxyNode] {
        try SubscriptionParser.parseSubscription(data, sourceID: sourceID)
    }
}
