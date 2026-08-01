import Foundation

/// sing-box LaunchAgent 的运行状态。
public enum ServiceState: Equatable, Sendable {
    case running
    case stopped
    case failed(String)

    public nonisolated static func == (lhs: ServiceState, rhs: ServiceState) -> Bool {
        switch (lhs, rhs) {
        case (.running, .running), (.stopped, .stopped): true
        case (.failed(let lhsReason), .failed(let rhsReason)): lhsReason == rhsReason
        default: false
        }
    }

    public nonisolated var label: String {
        switch self {
        case .running: "运行中"
        case .stopped: "已停止"
        case .failed: "异常"
        }
    }

    public nonisolated var symbol: String {
        switch self {
        case .running: "checkmark.circle.fill"
        case .stopped: "pause.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    public nonisolated var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    public nonisolated var failureReason: String? {
        if case .failed(let reason) = self { return reason }
        return nil
    }
}

/// 解析 `launchctl print` 的输出。
///
/// 单独拎成纯函数是为了能测：真机上很难稳定造出「已加载但上次异常退出」这种状态，
/// 而这恰恰是最需要在界面上说清楚的一种。
public enum LaunchCtlStatusParser {
    public nonisolated static func parse(exitCode: Int32, output: String) -> ServiceState {
        // 非零退出码意味着服务压根没被 launchd 加载，不是「异常」而是「没在跑」。
        guard exitCode == 0 else { return .stopped }
        if output.contains("state = running") { return .running }
        if let lastExitCode = firstCapture(in: output, pattern: #"last exit code = ([0-9]+)"#),
           lastExitCode != "0" {
            let state = firstCapture(in: output, pattern: #"state = ([A-Za-z]+)"#) ?? "unknown"
            return .failed("launchctl state \(state), last exit code \(lastExitCode)")
        }
        return .stopped
    }

    private nonisolated static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
