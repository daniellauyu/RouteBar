import Combine
import Foundation
import SwiftUI
import os

/// 日志级别的展示属性（枚举本身在 Domain 层，引擎也要用）。
extension LogLevel {
    var tint: Color {
        switch self {
        case .info: .secondary
        case .notice: .blue
        case .warning: .orange
        case .error: .red
        }
    }

    var osType: OSLogType {
        switch self {
        case .info: .info
        case .notice: .default
        case .warning: .error
        case .error: .fault
        }
    }
}

/// 这条记录是谁写的。
///
/// 两边混在一列里显示是有意的——排查时你想知道的是「按时间顺序发生了什么」，
/// 而不是「先看这份文件再看那份」。但必须标出来源：RouteBar 说的是它自己做了什么，
/// sing-box 说的是数据面发生了什么，混淆两者会把「配置装好了」当成「连接成功了」。
enum LogSource: String, CaseIterable, Identifiable, Sendable {
    case routeBar = "RouteBar"
    case singBox = "sing-box"

    var id: String { rawValue }
}

struct RuntimeLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let category: String
    let message: String
    var source: LogSource = .routeBar
}

/// 应用内运行日志：内存环形缓冲（保留最近 1000 条，重启清空），可复制或导出。
///
/// 同时镜像到系统统一日志（`subsystem == com.liuyude.RouteBar.app`），所以「重启清空」
/// 不代表历史丢失——要查更早的记录去 Console.app 或 `log show`。
/// 这也是这次去掉 `update.log` 的原因：同一批事件不必再单独维护一份纯文本文件。
@MainActor
final class RuntimeLog: ObservableObject {
    static let shared = RuntimeLog()

    @Published private(set) var entries: [RuntimeLogEntry] = []

    private let capacity = 1000
    private let logger = Logger(subsystem: "com.liuyude.RouteBar.app", category: "runtime")

    private init() {}

    func log(_ level: LogLevel, _ category: String, _ message: String) {
        append(RuntimeLogEntry(timestamp: Date(), level: level, category: category, message: message))
    }

    /// 并入 sing-box 自己写的日志。
    ///
    /// 不镜像到系统统一日志：那些行已经在 sing-box 的日志文件里了，再复制一份进
    /// `log show` 只会让同一件事出现两遍，还把 RouteBar 自己的记录冲淡。
    func ingest(_ line: SingBoxLogLine) {
        entries.append(RuntimeLogEntry(timestamp: line.timestamp ?? Date(),
                                       level: line.level,
                                       category: line.category,
                                       message: line.message,
                                       source: .singBox))
        trim()
    }

    private func append(_ entry: RuntimeLogEntry) {
        entries.append(entry)
        trim()
        logger.log(level: entry.level.osType,
                   "[\(entry.category, privacy: .public)] \(entry.message, privacy: .public)")
    }

    private func trim() {
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    func info(_ category: String, _ message: String) { log(.info, category, message) }
    func notice(_ category: String, _ message: String) { log(.notice, category, message) }
    func warning(_ category: String, _ message: String) { log(.warning, category, message) }
    func error(_ category: String, _ message: String) { log(.error, category, message) }

    func clear() { entries.removeAll() }

    /// 导出为纯文本（时间升序）。
    func exportText(_ entries: [RuntimeLogEntry]? = nil) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return (entries ?? self.entries).map {
            "[\(formatter.string(from: $0.timestamp))] [\($0.level.rawValue)] "
                + "[\($0.source.rawValue)] [\($0.category)] \($0.message)"
        }.joined(separator: "\n")
    }
}
