import Foundation
import Darwin

public enum NetworkTestRoute: Sendable, Equatable {
    case system
    case withoutProxy
    case node(name: String, port: Int)

    public nonisolated var title: String {
        switch self {
        case .system: "系统代理"
        case .withoutProxy: "不使用 HTTP / SOCKS 代理"
        case let .node(name, port): "\(name) · 127.0.0.1:\(port)"
        }
    }

    public nonisolated var explanation: String {
        switch self {
        case .system: "使用 macOS 系统代理；不读取 OpenCode 的代理环境变量。系统可能按目标域名分流。"
        case .withoutProxy: "绕过 HTTP / SOCKS 代理，适合对比 NO_PROXY 配置。Surge 增强模式、VPN 和网关仍可能接管流量。"
        case .node: "两类请求都经过所选节点的本地 SOCKS 端口；节点服务端仍可能按目标分流。"
        }
    }
}

/// HTTP 响应与连接指标。localAddress 是 NAT 之前的套接字地址，绝不是公网出口证明。
public struct NetworkProbeResponse: Sendable {
    public let statusCode: Int?
    public let body: Data
    public let requestID: String?
    public let localAddress: String?
    public let remoteAddress: String?
    public let usedProxy: Bool?
    public let elapsed: TimeInterval
    public let failure: String?

    public nonisolated init(statusCode: Int? = nil, body: Data = Data(), requestID: String? = nil,
                            localAddress: String? = nil, remoteAddress: String? = nil,
                            usedProxy: Bool? = nil, elapsed: TimeInterval = 0, failure: String? = nil) {
        self.statusCode = statusCode
        self.body = body
        self.requestID = requestID
        self.localAddress = localAddress
        self.remoteAddress = remoteAddress
        self.usedProxy = usedProxy
        self.elapsed = elapsed
        self.failure = failure
    }
}

public struct NetworkReferenceIP: Sendable {
    public let service: String
    public let address: String?
    public let failure: String?

    public nonisolated init(service: String, address: String?, failure: String?) {
        self.service = service
        self.address = address
        self.failure = failure
    }
}

public struct NetworkTestResult: Sendable {
    public let testedAt: Date
    public let route: NetworkTestRoute
    public let targetURL: String
    public let suppliedAPIKey: Bool
    public let response: NetworkProbeResponse
    public let errorCode: String?
    public let message: String?
    public let references: [NetworkReferenceIP]

    public nonisolated init(testedAt: Date = .now, route: NetworkTestRoute, targetURL: String,
                            suppliedAPIKey: Bool, response: NetworkProbeResponse,
                            errorCode: String?, message: String?, references: [NetworkReferenceIP]) {
        self.testedAt = testedAt
        self.route = route
        self.targetURL = targetURL
        self.suppliedAPIKey = suppliedAPIKey
        self.response = response
        self.errorCode = errorCode
        self.message = message
        self.references = references
    }

    public nonisolated var ipRestricted: Bool {
        response.statusCode == 403 && (message?.localizedCaseInsensitiveContains("IP access denied") == true)
    }

    public nonisolated var summary: String {
        if let failure = response.failure { return "阿里云连接失败：\(failure)" }
        if ipRestricted { return "阿里云拒绝访问：API Key 的 IP 限制未通过" }
        guard let status = response.statusCode else { return "未收到阿里云 HTTP 响应" }
        if status == 401 { return suppliedAPIKey ? "已连接阿里云，API Key 验证未通过" : "已连接阿里云；未提供 API Key，尚未验证 IP 权限" }
        if (200..<300).contains(status) { return "阿里云模型列表接口访问成功" }
        return "已收到阿里云响应：HTTP \(status)"
    }

    public nonisolated var referenceIPsDiffer: Bool {
        Set(references.compactMap(\.address)).count > 1
    }

    // DashScope models 接口没有已知的客户端 IP 回显契约。不得从 remoteAddress、
    // X-Forwarded-For、通用 IP 网站或错误正文里的任意 IP 推导“已确认”。
    public nonisolated var sourceIPExplanation: String {
        "阿里云来源 IP 未确认：该接口未回显客户端公网 IP。下方 IP 仅由各检测网站观测，不能直接作为阿里云白名单依据。"
    }

    public nonisolated var report: String {
        var lines = ["RouteBar · 阿里云网络测试", "时间：\(testedAt.formatted())", "路径：\(route.title)",
                     route.explanation, "请求：GET \(targetURL)", "\(summary)", sourceIPExplanation]
        if let status = response.statusCode { lines.append("HTTP：\(status)") }
        if let errorCode { lines.append("错误码：\(errorCode)") }
        if let message { lines.append("服务端消息：\(message)") }
        if let requestID = response.requestID { lines.append("Request ID：\(requestID)") }
        if let local = response.localAddress { lines.append("本机连接地址（非公网出口）：\(local)") }
        if let remote = response.remoteAddress { lines.append("连接对端（非出口 IP）：\(remote)") }
        lines.append("耗时：\(Int(response.elapsed * 1000)) ms")
        for reference in references {
            lines.append("参考出口 · \(reference.service)：\(reference.address ?? reference.failure ?? "未获取")")
        }
        if referenceIPsDiffer { lines.append("不同检测网站返回了不同 IP，存在分流或多出口。") }
        lines.append("仅测试本次所选路径，不代表历史请求或 OpenCode 的实际路径。")
        return lines.joined(separator: "\n")
    }
}

public enum NetworkTestParser {
    /// 只接受检测服务约定的完整字段，不从 HTML、错误页或任意文本里搜 IP。
    public nonisolated static func referenceIP(_ data: Data, service: String) -> String? {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String?
        if service == "myip.ipip.net", text.hasPrefix("当前 IP："),
           let end = text.range(of: "  来自于：") {
            candidate = String(text[text.index(text.startIndex, offsetBy: 6)..<end.lowerBound])
                .trimmingCharacters(in: .whitespaces)
        } else if service == "Cloudflare" {
            let fields = text.split(separator: "\n").filter { $0.hasPrefix("ip=") }
            candidate = fields.count == 1 ? String(fields[0].dropFirst(3)) : nil
        } else {
            candidate = nil
        }
        guard let candidate else { return nil }
        var v4 = in_addr()
        var v6 = in6_addr()
        let valid = candidate.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
        return valid ? candidate : nil
    }
}
