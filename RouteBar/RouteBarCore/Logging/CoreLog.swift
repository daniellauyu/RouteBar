import os

/// RouteBarCore 的日志门面。
///
/// 与应用内的 `RuntimeLog` 相互独立，子系统区分为 `.core`，便于单独过滤引擎日志：
/// `log stream --predicate 'subsystem == "com.liuyude.RouteBar.core"'`
public enum CoreLog {
    public nonisolated static let subsystem = "com.liuyude.RouteBar.core"

    /// 受控命令执行（launchctl / sing-box check）。
    public nonisolated static let command = Logger(subsystem: subsystem, category: "command")
    /// 订阅拉取与解析。
    public nonisolated static let subscription = Logger(subsystem: subsystem, category: "subscription")
    /// 配置生成与安装。
    public nonisolated static let configuration = Logger(subsystem: subsystem, category: "configuration")
    /// 延迟测试。
    public nonisolated static let latency = Logger(subsystem: subsystem, category: "latency")
}
