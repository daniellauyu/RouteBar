import os
import Foundation

/// 节点延迟测试。
///
/// 通过 sing-box 已经监听的本地 SOCKS 端口去请求，测的才是「这条链路端到端能不能用」——
/// 直接连节点服务器只能说明 TCP 可达，Reality 握手失败或落地被墙一样看不出来。
/// 所以测速的前提是配置已生成且服务在跑。
public struct LatencyTester: Sendable {
    public var testURL: URL
    public var timeout: TimeInterval
    /// 每个节点连测几次、取最好的一次。
    ///
    /// 单次采样没有意义：实测同一个节点连测五次，最快 193ms、最慢 1207ms——
    /// 只测一次的话，一次偶发抖动就把这个节点判了死刑。取最小值而不是平均值，
    /// 是因为要衡量的是「这条链路能有多快」，慢的那几次是噪声不是能力。
    public var samples: Int

    public nonisolated init(testURL: URL = URL(string: LatencyTestEndpoint.fallback.rawValue)!,
                            timeout: TimeInterval = 8,
                            samples: Int = 3) {
        self.testURL = testURL
        self.timeout = timeout
        self.samples = max(1, samples)
    }

    /// 并发测试一批节点，限制同时在跑的数量。
    ///
    /// 不限并发的话，几百个节点会同时向 sing-box 发起连接，节点自身的延迟被排队时间淹没，
    /// 测出来的数字没有可比性。
    public nonisolated func test(_ mapped: [PortMappedNode], maximumConcurrency: Int = 6) async -> [String: LatencyRecord] {
        await withTaskGroup(of: (String, LatencyRecord).self, returning: [String: LatencyRecord].self) { group in
            var iterator = mapped.makeIterator()
            for _ in 0..<min(maximumConcurrency, mapped.count) {
                if let item = iterator.next() { group.addTask { await test(item) } }
            }
            var results: [String: LatencyRecord] = [:]
            while let result = await group.next() {
                results[result.0] = result.1
                if let item = iterator.next() { group.addTask { await test(item) } }
            }
            return results
        }
    }

    /// 成功时继续采样并取最好的一次；第一次失败就停止。
    ///
    /// 对成功节点多采几次可以滤掉链路抖动。失败尤其是超时则通常说明节点已经不可用，
    /// 继续做满三次只会让一个死节点把整批测速从 8 秒拖到 24 秒。
    public nonisolated func test(_ mapped: PortMappedNode) async -> (String, LatencyRecord) {
        var best: LatencyRecord?
        for _ in 0..<samples {
            let (_, record) = await probe(mapped)
            if record.outcome == .success, let milliseconds = record.milliseconds {
                if best?.outcome != .success || milliseconds < (best?.milliseconds ?? .max) {
                    best = record
                }
            } else {
                // 已经成功过时保留成功结果；首次即失败时保留具体失败原因。
                if case nil = best { best = record }
                break
            }
        }
        return (mapped.node.id, best ?? LatencyRecord(outcome: .connectionFailed, milliseconds: nil))
    }

    private nonisolated func probe(_ mapped: PortMappedNode) async -> (String, LatencyRecord) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.connectionProxyDictionary = [
            "SOCKSEnable": true, "SOCKSProxy": "127.0.0.1", "SOCKSPort": mapped.localPort,
        ]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let metrics = LatencyTaskMetricsCollector()
        let start = ContinuousClock.now
        do {
            var request = URLRequest(url: testURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (_, response) = try await session.data(for: request, delegate: metrics)
            let elapsed = start.duration(to: .now)
            let milliseconds = metrics.milliseconds(fallback: elapsed)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let outcome: LatencyOutcome = (200..<400).contains(code) ? .success : .httpFailed
            return (mapped.node.id, LatencyRecord(outcome: outcome, milliseconds: outcome == .success ? milliseconds : nil))
        } catch let error as URLError {
            // 记下 URLError 的原始码：界面上只有「连接失败」三个字，而这一类失败里
            // 混着完全不同的东西——节点真挂了（-1004）、代理端口没开（-1004）、
            // ATS 拦掉了明文测速端点（-1022，会让所有节点在零点几秒内一起变红）。
            // 不记的话，「全部失败」这种最需要解释的情况恰恰什么线索都没有。
            CoreLog.latency.debug("端口 \(mapped.localPort) 测速失败：URLError \(error.code.rawValue)")
            let outcome: LatencyOutcome = error.code == .timedOut ? .timeout : .connectionFailed
            return (mapped.node.id, LatencyRecord(outcome: outcome, milliseconds: nil))
        } catch {
            return (mapped.node.id, LatencyRecord(outcome: .connectionFailed, milliseconds: nil))
        }
    }
}

/// URLSession 的完整任务耗时包含 SOCKS、Reality 和目标站连接。为贴近 Surge 的显示结果，
/// 这里只取代理隧道建立后从 HTTP 请求发出到收到响应首字节的时间；指标缺失时退回完整耗时。
private final class LatencyTaskMetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var requestStart: Date?
    private var responseStart: Date?

    nonisolated func urlSession(_ session: URLSession,
                               task: URLSessionTask,
                               didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let transaction = metrics.transactionMetrics.reversed().first(where: {
            $0.requestStartDate != nil && $0.responseStartDate != nil
        }) else { return }

        lock.lock()
        requestStart = transaction.requestStartDate
        responseStart = transaction.responseStartDate
        lock.unlock()
    }

    nonisolated func milliseconds(fallback: Duration) -> Int {
        lock.lock()
        let start = requestStart
        let end = responseStart
        lock.unlock()
        return LatencyMeasurement.milliseconds(
            requestStart: start,
            responseStart: end,
            fallback: fallback
        )
    }
}
