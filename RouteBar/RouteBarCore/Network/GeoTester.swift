import os
import Foundation

/// 节点落地探测。
///
/// 和测速走同一条路：经 sing-box 已经监听的本地 SOCKS 端口发请求。因此这里测到的
/// 「出口 IP」就是这个节点真正把流量送出去的那个地址——直连节点服务器只能知道它对外
/// 宣称的入口，落地在哪完全是另一回事（中转、二级跳都很常见）。
///
/// 探测的对端是 Cloudflare 的 `cdn-cgi/trace`：不需要 key、没有速率限制、走 HTTPS，
/// 而且几乎在所有出口都连得通——这恰恰是最需要探测的那批线路的前提。
///
/// 请求经节点发出，所以**用户的真实 IP 不外泄**；但机场看得见这次请求，
/// 这一点在界面上要说清楚，不能替用户默认。
public struct GeoTester: Sendable {
    public var endpoint: URL
    public var timeout: TimeInterval

    public nonisolated init(endpoint: URL = CloudflareTrace.endpoint, timeout: TimeInterval = 10) {
        self.endpoint = endpoint
        self.timeout = timeout
    }

    /// 并发探测一批节点，限制同时在跑的数量。
    ///
    /// 与测速同理：几百个节点同时握手会让结果彼此干扰。这里还多一层考虑——同一时刻
    /// 从太多出口打同一个对端，看着像扫描。
    public nonisolated func probe(_ mapped: [PortMappedNode],
                                  maximumConcurrency: Int = 6) async -> [String: GeoRecord] {
        await withTaskGroup(of: (String, GeoRecord).self, returning: [String: GeoRecord].self) { group in
            var iterator = mapped.makeIterator()
            for _ in 0..<min(maximumConcurrency, mapped.count) {
                if let item = iterator.next() { group.addTask { await probe(item) } }
            }
            var results: [String: GeoRecord] = [:]
            while let result = await group.next() {
                results[result.0] = result.1
                if let item = iterator.next() { group.addTask { await probe(item) } }
            }
            return results
        }
    }

    public nonisolated func probe(_ mapped: PortMappedNode) async -> (String, GeoRecord) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.connectionProxyDictionary = [
            "SOCKSEnable": true, "SOCKSProxy": "127.0.0.1", "SOCKSPort": mapped.localPort,
        ]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: endpoint)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // 固定一个不含版本号的 UA，和订阅拉取同理：对端的行为不该随 RouteBar 升级而变。
        request.setValue("RouteBar (macOS)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                return (mapped.node.entryID, GeoRecord(outcome: .failed))
            }
            // 解析失败 = 拿到的不是 trace 的输出（最常见的是被中间设备换成了门户页）。
            // 这种情况必须判失败，不能把半截 HTML 里碰巧出现的字符串当成落地地区。
            guard let record = CloudflareTrace.parse(String(decoding: data, as: UTF8.self)) else {
                CoreLog.latency.debug("端口 \(mapped.localPort) 落地探测：响应不是 trace 格式")
                return (mapped.node.entryID, GeoRecord(outcome: .failed))
            }
            return (mapped.node.entryID, record)
        } catch let error as URLError {
            CoreLog.latency.debug("端口 \(mapped.localPort) 落地探测失败：URLError \(error.code.rawValue)")
            return (mapped.node.entryID, GeoRecord(outcome: .failed))
        } catch {
            return (mapped.node.entryID, GeoRecord(outcome: .failed))
        }
    }
}
