import Foundation

/// sing-box 写出来的一行日志，拆成 RouteBar 的日志页能直接用的形状。
public struct SingBoxLogLine: Sendable, Equatable {
    /// 启动失败那类日志（logrus 风格）不带时间戳，只好为 nil，由调用方补当前时间。
    public let timestamp: Date?
    public let level: LogLevel
    /// 子系统：`outbound/vless`、`network`、`connection`……用作日志页里的分类列。
    public let category: String
    public let message: String

    public nonisolated init(timestamp: Date?, level: LogLevel, category: String, message: String) {
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
    }
}

/// 把 sing-box 的日志文本解析成结构化条目。
///
/// 为什么需要它：sing-box 把**所有**级别都写进 stderr，于是 RouteBar 那个叫「错误日志」
/// 的文件里其实 95% 是 INFO。用户看到一屏 `outbound connection to ...` 会以为出了问题，
/// 而真正的 ERROR 混在里面根本挑不出来。解析出级别之后，才谈得上「只看要紧的」。
///
/// 纯字符串处理，所以放在 Domain：日志格式是 sing-box 定的，我们只能靠样本推断，
/// 而推断出来的规则必须能用测试钉住——线上换个版本改了格式，这里要第一时间发现。
public enum SingBoxLogParser {
    /// sing-box 给级别和连接号加了 ANSI 颜色。直接展示会看到一堆 `[36m` 之类的乱码，
    /// 而按级别过滤更是先要把颜色码剥掉才认得出 `INFO`。
    public nonisolated static func stripANSI(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var iterator = text.makeIterator()
        var pending: Character?
        while let character = pending ?? iterator.next() {
            pending = nil
            guard character == "\u{1B}" else {
                result.append(character)
                continue
            }
            // CSI 序列：ESC [ 参数… 结束字母。吃到结束字母为止。
            guard let next = iterator.next() else { break }
            guard next == "[" else {
                pending = next
                continue
            }
            while let inside = iterator.next() {
                if inside.isLetter { break }
            }
        }
        return result
    }

    /// 级别名到 `LogLevel` 的映射。
    ///
    /// `NOTICE` 是 RouteBar 自己用来标记「我做了一件事」的级别，sing-box 从不产出它——
    /// 之所以也认，是因为归档里同时存着 RouteBar 自己的记录，读回来时要能还原成
    /// notice。少了这一档的话它会退化成普通 info，「刚做过什么」就淹在流水里了。
    public nonisolated static func level(named name: String) -> LogLevel? {
        switch name.uppercased() {
        case "TRACE", "DEBUG", "INFO": .info
        case "NOTICE": .notice
        case "WARN", "WARNING": .warning
        case "ERROR", "FATAL", "PANIC": .error
        default: nil
        }
    }

    /// 解析一行。认不出来时返回 nil——宁可漏掉一行，也不要把半截文本当成事件塞进日志。
    public nonisolated static func parse(_ rawLine: String) -> SingBoxLogLine? {
        let line = stripANSI(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }

        // 形态一（绝大多数）：`+0800 2026-08-10 15:39:48 INFO [1549230756 441ms] outbound/vless[...]: 正文`
        if let parsed = parseTimestamped(line) { return parsed }
        // 形态二（启动失败）：`FATAL[0000] start service: ...`——logrus 的默认格式，没有时间戳。
        if let parsed = parseLogrus(line) { return parsed }
        return nil
    }

    /// 解析一整段（`tail` 拿到的那种多行文本）。认不出的行安静丢掉。
    public nonisolated static func parse(tail: String) -> [SingBoxLogLine] {
        tail.split(separator: "\n", omittingEmptySubsequences: true).compactMap { parse(String($0)) }
    }

    /// 反向：把一条记录写回 sing-box 的行格式。
    ///
    /// 归档文件用**同一种格式**，于是读回来时复用 `parse`，不必再维护第二套读写规则——
    /// 两套格式意味着两处都要改、而只改一处的后果是归档能写不能读，且要等到用户
    /// 去翻历史时才发现。写出去的不带 ANSI：颜色是给终端看的，文件里只是噪声。
    public nonisolated static func render(_ line: SingBoxLogLine) -> String {
        let stamp = formatter.string(from: line.timestamp ?? Date())
        let head = line.category == "sing-box" ? "" : "\(line.category): "
        return "\(stamp) \(name(of: line.level)) \(head)\(line.message)"
    }

    private nonisolated static func name(of level: LogLevel) -> String {
        switch level {
        case .info: "INFO"
        case .notice: "NOTICE"
        case .warning: "WARN"
        case .error: "ERROR"
        }
    }

    // MARK: - 两种形态

    private nonisolated static func parseTimestamped(_ line: String) -> SingBoxLogLine? {
        // `+0800 2026-08-10 15:39:48 LEVEL 其余`
        let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
        guard parts.count >= 4,
              parts[0].hasPrefix("+") || parts[0].hasPrefix("-"),
              let level = level(named: String(parts[3])) else { return nil }
        let stamp = "\(parts[0]) \(parts[1]) \(parts[2])"
        let remainder = parts.count > 4 ? String(parts[4]) : ""
        let (category, message) = splitCategory(dropConnectionID(remainder))
        return SingBoxLogLine(timestamp: date(from: stamp), level: level,
                              category: category, message: message)
    }

    private nonisolated static func parseLogrus(_ line: String) -> SingBoxLogLine? {
        // `FATAL[0000] 正文`：级别紧跟一个方括号里的启动秒数。
        guard let bracket = line.firstIndex(of: "["),
              let level = level(named: String(line[line.startIndex..<bracket])),
              let close = line[bracket...].firstIndex(of: "]") else { return nil }
        let remainder = String(line[line.index(after: close)...])
            .trimmingCharacters(in: .whitespaces)
        let (category, message) = splitCategory(remainder)
        return SingBoxLogLine(timestamp: nil, level: level, category: category, message: message)
    }

    // MARK: - 拆解正文

    /// 去掉 `[连接号 耗时]` 那一段。
    ///
    /// 连接号只在把同一条连接的多行串起来时有用，而日志页是按事件读的，
    /// 每行前面挂一串十位数字只会把真正的内容推到看不见的地方。
    private nonisolated static func dropConnectionID(_ text: String) -> String {
        guard text.hasPrefix("["), let close = text.firstIndex(of: "]") else { return text }
        return String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
    }

    /// 首段像子系统名就抽出来当分类。
    ///
    /// 判据是「不含空格」：`outbound/vless[out-routebar-28]`、`network`、`connection` 都算，
    /// 而 `start service: ...` 那种整句不算——把半句话塞进分类列，两边都会显示不全。
    private nonisolated static func splitCategory(_ text: String) -> (String, String) {
        guard let colon = text.range(of: ": ") else { return ("sing-box", text) }
        let head = String(text[text.startIndex..<colon.lowerBound])
        guard !head.isEmpty, !head.contains(" ") else { return ("sing-box", text) }
        // 出站标签对应 RouteBar 的节点端口；保留在正文里，归档后仍能回查出口。
        let category = head.split(separator: "[", maxSplits: 1).first.map(String.init) ?? head
        let message = String(text[colon.upperBound...])
        if category.hasPrefix("outbound/"), let bracket = head.firstIndex(of: "[") {
            return (category, "\(head[bracket...]) \(message)")
        }
        return (category, message)
    }

    private nonisolated static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "Z yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private nonisolated static func date(from text: String) -> Date? {
        formatter.date(from: text)
    }
}
