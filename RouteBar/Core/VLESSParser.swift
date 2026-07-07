import CryptoKit
import Foundation

public enum VLESSParser {
    public static func parseSubscription(_ data: Data, sourceID: UUID) throws -> [ProxyNode] {
        let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func parseURI(_ line: String, sourceID: UUID) -> ProxyNode? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("vless://"),
              let components = URLComponents(string: trimmed),
              let server = components.host,
              let port = components.port,
              let uuid = components.user, !uuid.isEmpty else { return nil }

        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        guard values["security"] == "reality", values["type", default: "tcp"] == "tcp" else { return nil }

        let name = components.fragment?.removingPercentEncoding?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (name?.isEmpty == false ? name : nil) ?? server
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
