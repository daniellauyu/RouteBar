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
    case gstatic = "https://www.gstatic.com/generate_204"
    case apple = "https://captive.apple.com/hotspot-detect.html"

    public nonisolated var id: String { rawValue }

    public nonisolated var label: String {
        switch self {
        case .cloudflare: "Cloudflare"
        case .gstatic: "Google gstatic"
        case .apple: "Apple"
        }
    }

    /// 默认用 Cloudflare：它的检测端点有 anycast 加持，落地在哪都能就近命中，
    /// 测出来更接近节点本身的能力而不是「节点到某个特定机房有多远」。
    public nonisolated static let fallback = LatencyTestEndpoint.cloudflare

    /// 把设置里存的字符串解析成可用的 URL，非法值回落到默认端点。
    public nonisolated static func resolve(_ raw: String) -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme != nil, url.host != nil {
            return url
        }
        return URL(string: fallback.rawValue)!
    }
}
