import Foundation
import Testing
@testable import RouteBarDomain

/// 这些样本都是从真机上那份 65 MB 的日志里原样抄下来的，包括 ANSI 颜色码。
/// 格式是 sing-box 定的、只能靠样本推断，所以必须钉住——上游哪天改了格式，
/// 应当是这里先红，而不是用户先看到一屏乱码。
@Suite struct SingBoxLogParserTests {
    /// 最常见的一行：带时区前缀、带颜色、带连接号与耗时。
    @Test func parsesTheCommonConnectionLine() throws {
        let raw = "+0800 2026-08-10 15:39:48 \u{1B}[36mINFO\u{1B}[0m "
            + "[\u{1B}[38;5;180m1549230756\u{1B}[0m 441ms] "
            + "outbound/vless[out-routebar-28]: outbound connection to chatgpt.com:443"

        let line = try #require(SingBoxLogParser.parse(raw))

        #expect(line.level == .info)
        #expect(line.category == "outbound/vless")
        // 连接号与耗时被丢掉：运行日志按事件读，十位数字只会把正文挤到看不见。
        #expect(line.message == "outbound connection to chatgpt.com:443")
        #expect(line.timestamp != nil)
    }

    /// 真正的错误必须落到 `.error`，否则它会和 40 万行 INFO 一起被过滤掉。
    @Test func mapsErrorLevels() throws {
        let raw = "+0800 2026-08-10 14:50:34 \u{1B}[31mERROR\u{1B}[0m "
            + "[\u{1B}[38;5;222m339859424\u{1B}[0m 10.36s] "
            + "connection: report handshake success: write tcp 127.0.0.1:7749->127.0.0.1:62241: write: broken pipe"

        let line = try #require(SingBoxLogParser.parse(raw))

        #expect(line.level == .error)
        #expect(line.category == "connection")
        #expect(line.message.contains("broken pipe"))
    }

    /// 没有连接号的那种（网络状态变化）。
    @Test func parsesLinesWithoutConnectionID() throws {
        let raw = "+0800 2026-07-06 15:28:17 \u{1B}[36mINFO\u{1B}[0m network: updated default interface en0, index 15"

        let line = try #require(SingBoxLogParser.parse(raw))

        #expect(line.level == .info)
        #expect(line.category == "network")
        #expect(line.message == "updated default interface en0, index 15")
    }

    /// 启动失败走的是 logrus 的默认格式：没有时间戳，级别后面直接跟启动秒数。
    /// 这行恰恰是最要紧的一类（端口占不上、配置起不来），不能因为格式不同就漏掉。
    @Test func parsesStartupFailureWithoutTimestamp() throws {
        let raw = "\u{1B}[31mFATAL\u{1B}[0m[0000] start service: start inbound/mixed[in-vless-01]: "
            + "listen tcp 127.0.0.1:7701: bind: operation not permitted"

        let line = try #require(SingBoxLogParser.parse(raw))

        #expect(line.level == .error)
        #expect(line.timestamp == nil)
        // 「start service」带空格，不是子系统名，不该被塞进分类列。
        #expect(line.category == "sing-box")
        #expect(line.message.contains("operation not permitted"))
    }

    @Test func stripsAnsiWithoutEatingRealText() {
        #expect(SingBoxLogParser.stripANSI("\u{1B}[31mERROR\u{1B}[0m x") == "ERROR x")
        #expect(SingBoxLogParser.stripANSI("没有颜色码") == "没有颜色码")
        // 方括号本身是正文的一部分时不能被吞掉。
        #expect(SingBoxLogParser.stripANSI("outbound[tag]: x") == "outbound[tag]: x")
    }

    /// 认不出来的行安静丢掉，不能把半截文本当成事件塞进日志。
    @Test func ignoresUnparseableLines() {
        #expect(SingBoxLogParser.parse("") == nil)
        #expect(SingBoxLogParser.parse("   ") == nil)
        #expect(SingBoxLogParser.parse("随便一行没有级别的东西") == nil)
        #expect(SingBoxLogParser.parse("+0800 2026-08-10 15:39:48 VERBOSE 未知级别") == nil)
    }

    /// 整段解析：只保留认得出的行，顺序不变。
    @Test func parsesWholeTailKeepingOrder() {
        let tail = """
        +0800 2026-08-10 15:39:48 \u{1B}[36mINFO\u{1B}[0m network: a
        垃圾行
        +0800 2026-08-10 15:39:49 \u{1B}[31mERROR\u{1B}[0m network: b

        +0800 2026-08-10 15:39:50 \u{1B}[36mINFO\u{1B}[0m network: c
        """

        let lines = SingBoxLogParser.parse(tail: tail)

        #expect(lines.count == 3)
        #expect(lines.map(\.message) == ["a", "b", "c"])
        #expect(lines.map(\.level) == [.info, .error, .info])
    }
}
