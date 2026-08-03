import Foundation

/// 测速用的探测端点。
///
/// 都是「返回 204 空响应」的连通性检测地址：响应体为空，测到的时间才是链路本身的开销，
/// 不掺杂下载内容的时间。
///
/// 换端点会系统性地改变所有数字（实测同一节点 gstatic 比 cp.cloudflare 慢 30–40%，
/// 因为落地后到目标的路径不同），所以**换了端点之后的结果不要和换之前的比**。
public enum LatencyTestEndpoint: String, CaseIterable, Identifiable, Sendable {
    case cloudflare = "https://cp.cloudflare.com/generate_204"
    case gstatic = "http://www.gstatic.com/generate_204"
    case apple = "https://captive.apple.com/hotspot-detect.html"

    public nonisolated var id: String { rawValue }

    public nonisolated var label: String {
        switch self {
        case .cloudflare: "Cloudflare"
        case .gstatic: "Google gstatic"
        case .apple: "Apple"
        }
    }

    /// 与当前 Surge 配置的 URL test 端点保持一致，便于直接比较两边显示的延迟。
    /// 使用 HTTP 也避免把目标站 TLS 握手混进代理延迟。
    public nonisolated static let fallback = LatencyTestEndpoint.gstatic

    /// 把设置里存的字符串解析成可用的 URL，非法值回落到默认端点。
    public nonisolated static func resolve(_ raw: String) -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme != nil, url.host != nil {
            return url
        }
        return URL(string: fallback.rawValue)!
    }
}
