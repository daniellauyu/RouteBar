import Foundation

/// 节点延迟测试。
///
/// 通过 sing-box 已经监听的本地 SOCKS 端口去请求，测的才是「这条链路端到端能不能用」——
/// 直接连节点服务器只能说明 TCP 可达，Reality 握手失败或落地被墙一样看不出来。
/// 所以测速的前提是配置已生成且服务在跑。
public struct LatencyTester: Sendable {
    public var testURL: URL
    public var timeout: TimeInterval

    public nonisolated init(testURL: URL = URL(string: "https://www.gstatic.com/generate_204")!,
                            timeout: TimeInterval = 8) {
        self.testURL = testURL
        self.timeout = timeout
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

    public nonisolated func test(_ mapped: PortMappedNode) async -> (String, LatencyRecord) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.connectionProxyDictionary = [
            "SOCKSEnable": true, "SOCKSProxy": "127.0.0.1", "SOCKSPort": mapped.localPort,
        ]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let start = ContinuousClock.now
        do {
            let (_, response) = try await session.data(from: testURL)
            let elapsed = start.duration(to: .now)
            let milliseconds = Int(Double(elapsed.components.seconds) * 1000
                + Double(elapsed.components.attoseconds) / 1e15)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let outcome: LatencyOutcome = (200..<400).contains(code) ? .success : .httpFailed
            return (mapped.node.id, LatencyRecord(outcome: outcome, milliseconds: outcome == .success ? milliseconds : nil))
        } catch let error as URLError {
            let outcome: LatencyOutcome = error.code == .timedOut ? .timeout : .connectionFailed
            return (mapped.node.id, LatencyRecord(outcome: outcome, milliseconds: nil))
        } catch {
            return (mapped.node.id, LatencyRecord(outcome: .connectionFailed, milliseconds: nil))
        }
    }
}
