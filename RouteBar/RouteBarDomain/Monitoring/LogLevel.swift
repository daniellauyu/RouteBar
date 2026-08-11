import Foundation

/// 日志级别。
///
/// 定义在 Domain 层是因为引擎（`SubscriptionCoordinator`）也要产出带级别的消息，
/// 而引擎不能依赖 SwiftUI。颜色等展示属性由应用层扩展补上。
public enum LogLevel: String, CaseIterable, Identifiable, Comparable, Sendable {
    case info = "信息"
    case notice = "提示"
    case warning = "警告"
    case error = "错误"

    public nonisolated var id: String { rawValue }

    private nonisolated var order: Int {
        switch self {
        case .info: 0
        case .notice: 1
        case .warning: 2
        case .error: 3
        }
    }

    public nonisolated static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.order < rhs.order }

    public nonisolated var symbol: String {
        switch self {
        case .info: "info.circle"
        case .notice: "bell"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }
}

/// 引擎产出的一条待记录消息。
///
/// 引擎不直接写日志：它是 actor，而 `RuntimeLog` 是 `@MainActor`。让引擎返回消息、
/// 由应用层落到日志里，既避免了跨隔离域调用，也让「这次操作发生了什么」成为
/// 操作结果的一部分，而不是散落在各处的副作用。
public struct OutcomeMessage: Sendable {
    public let level: LogLevel
    public let category: String
    public let text: String

    public nonisolated init(_ level: LogLevel, _ category: String, _ text: String) {
        self.level = level
        self.category = category
        self.text = text
    }
}
