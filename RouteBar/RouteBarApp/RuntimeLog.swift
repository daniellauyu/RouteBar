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

/// RouteBar 自身事件的入口：写内存缓冲、镜像到系统统一日志、并交给日期归档。
///
/// 内存那份（最近 1000 条，重启清空）现在只服务于「刚发生的事要立刻可见」——
/// 日志页读的是归档文件，而归档要经过一次「写文件再读回来」，界面上会慢半拍。
/// 真正的历史在归档里：`~/Library/Application Support/RouteBar/logs/`。
///
/// 同时镜像到系统统一日志（`subsystem == com.liuyude.RouteBar.app`），
/// 更早的记录可以用 Console.app 或 `log show` 查。
@MainActor
final class RuntimeLog: ObservableObject {
    static let shared = RuntimeLog()

    @Published private(set) var entries: [RuntimeLogEntry] = []

    /// 把 RouteBar 自己的记录送去归档。
    ///
    /// 用闭包而不是让 RuntimeLog 直接持有引擎：它是个从各处被随手调用的单例
    /// （`log.info(...)` 遍布全应用），给它一个引擎依赖会让整条依赖链倒过来。
    /// 由 `AppModel` 在启动时装上。
    var archiver: ((RuntimeLogEntry) -> Void)?

    private let capacity = 1000
    private let logger = Logger(subsystem: "com.liuyude.RouteBar.app", category: "runtime")

    private init() {}

    func log(_ level: LogLevel, _ category: String, _ message: String) {
        append(RuntimeLogEntry(timestamp: Date(), level: level, category: category, message: message))
    }

    /// 并入 sing-box 自己写的日志。
    ///
    /// 既不镜像到系统统一日志、也不再归档一次：那些行已经在 sing-box 的日志文件里，
    /// 而归档由 `AppModel` 在读到它们时整批写过了。这里重复一遍只会让同一件事
    /// 出现两遍，还把 RouteBar 自己的记录冲淡。
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
        archiver?(entry)
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
