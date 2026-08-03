import Foundation

/// 把 URLSession 的任务阶段转换成用户看到的代理延迟。
///
/// `requestStart → responseStart` 用来贴近 Surge 的 URL test 显示结果：代理隧道已经建立后，
/// 从请求开始发送到收到首字节。任务指标缺失时才退回完整冷启动耗时，避免测速无结果。
public enum LatencyMeasurement {
    public nonisolated static func milliseconds(requestStart: Date?,
                                                 responseStart: Date?,
                                                 fallback: Duration) -> Int {
        if let requestStart, let responseStart {
            let interval = responseStart.timeIntervalSince(requestStart)
            if interval.isFinite, interval >= 0 {
                return Int((interval * 1_000).rounded())
            }
        }
        return milliseconds(fallback)
    }

    public nonisolated static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        let value = Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1e15
        guard value.isFinite else { return 0 }
        return max(0, Int(value.rounded()))
    }
}
