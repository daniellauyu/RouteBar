import CryptoKit
import Foundation

/// 解析机场订阅内容为节点列表。
///
/// 只收 `security=reality` 且 `type=tcp` 的 VLESS 节点：RouteBar 生成的 sing-box 配置就只写
/// 这一种出站，收下别的协议只会在 `sing-box check` 阶段炸掉，不如在入口就过滤。
public enum VLESSParser {
    public nonisolated static func parseSubscription(_ data: Data, sourceID: UUID) throws -> [ProxyNode] {
        let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // 机场返回的可能是明文 URI 列表，也可能是整份 base64。先看有没有明文标记，
        // 避免把明文当 base64 解出一堆乱码。
        let body: String
        if raw.contains("vless://") {
            body = raw
        } else if let decoded = Data(base64Encoded: raw, options: .ignoreUnknownCharacters) {
            body = String(decoding: decoded, as: UTF8.self)
        } else {
            body = ""
        }

        let nodes = body.components(separatedBy: .newlines).compactMap { parseURI($0, sourceID: sourceID) }
        return NodeCatalog.merge(nodes)
    }

    private nonisolated static func parseURI(_ line: String, sourceID: UUID) -> ProxyNode? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("vless://"),
              let components = URLComponents(string: trimmed),
              let server = components.host,
              let port = components.port,
              let uuid = components.user, !uuid.isEmpty else { return nil }

        let values = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                                uniquingKeysWith: { first, _ in first })
        guard values["security"] == "reality", values["type", default: "tcp"] == "tcp" else { return nil }

        let name = components.fragment?.removingPercentEncoding?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (name?.isEmpty == false ? name : nil) ?? server
        // 指纹只取连接参数，不含节点名：机场改名不应该让它变成一个「新节点」。
        let identity = [server, String(port), uuid, values["pbk", default: ""], values["sid", default: ""]].joined(separator: "|")
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()

        return ProxyNode(
            id: digest,
            name: displayName,
            server: server,
            serverPort: port,
            uuid: uuid,
            flow: values["flow", default: "xtls-rprx-vision"],
            serverName: values["sni", default: server],
            publicKey: values["pbk", default: ""],
            shortID: values["sid", default: ""],
            fingerprint: values["fp", default: "chrome"],
            sourceIDs: [sourceID],
            isEnabled: true
        )
    }
}
