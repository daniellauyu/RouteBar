import Foundation
import Testing
@testable import RouteBarDomain

@Suite struct LogArchiveTests {
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!

    private func day(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = shanghai
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text)!
    }

    @Test func fileNameRoundTrips() throws {
        let name = LogArchive.fileName(for: day("2026-08-11 09:20:01"), timeZone: shanghai)
        #expect(name == "routebar-2026-08-11.log")

        let parsed = try #require(LogArchive.date(fromFileName: name, timeZone: shanghai))
        #expect(LogArchive.fileName(for: parsed, timeZone: shanghai) == name)
    }

    /// 1.15.0 写出来的 `singbox-` 文件仍然要认，否则升级当天之前的记录会从日期
    /// 列表里消失——文件还在盘上，只是没人认领。
    @Test func stillRecognisesLegacyFileNames() {
        #expect(LogArchive.date(fromFileName: "singbox-2026-08-11.log") != nil)
        #expect(LogArchive.date(fromFileName: "routebar-2026-08-11.log") != nil)
    }

    /// 读某一天要把新旧两个文件名都拼进来，否则跨版本的那天只会显示一半。
    @Test func readsBothNamesForTheSameDay() {
        let names = LogArchive.fileNames(for: day("2026-08-11 09:00:00"), timeZone: shanghai)
        #expect(names == ["routebar-2026-08-11.log", "singbox-2026-08-11.log"])
    }

    /// 目录里可能有别的东西，认不出的一律不当归档——否则会把无关文件算进保留期后删掉。
    @Test func rejectsForeignFileNames() {
        #expect(LogArchive.date(fromFileName: "state.json") == nil)
        #expect(LogArchive.date(fromFileName: "routebar-.log") == nil)
        #expect(LogArchive.date(fromFileName: "routebar-2026-13-45.log") == nil)
        #expect(LogArchive.date(fromFileName: "routebar-2026-08-11.txt") == nil)
    }

    // MARK: - 来源标注

    /// RouteBar 自己的记录靠分类前缀标出来，往返必须一字不差——错了的话
    /// 「来源」列会把两边说反，而这一列正是用来区分「谁说的」。
    @Test func routeBarCategoryRoundTrips() {
        let tagged = LogArchive.tag(routeBarCategory: "服务")

        #expect(tagged == "routebar/服务")
        let untagged = LogArchive.untag(tagged)
        #expect(untagged.category == "服务")
        #expect(untagged.isRouteBar)
    }

    /// sing-box 自己的分类不带前缀，不能被误判成 RouteBar 的。
    @Test func singBoxCategoriesAreLeftAlone() {
        for category in ["outbound/vless", "connection", "network", "sing-box"] {
            let untagged = LogArchive.untag(category)
            #expect(untagged.category == category)
            #expect(!untagged.isRouteBar)
        }
    }

    // MARK: - 分桶与过期

    /// 分桶按每一行**自己**的时间戳。
    ///
    /// RouteBar 不常驻：它关着时 sing-box 照样写，下次启动一口气读到的内容可能横跨
    /// 好几天。一律算作「今天」的话，那几天的记录会全堆进一个文件，日期就没意义了。
    @Test func bucketsByEachLineOwnDate() {
        let lines = [
            SingBoxLogLine(timestamp: day("2026-08-09 23:59:59"), level: .error, category: "c", message: "a"),
            SingBoxLogLine(timestamp: day("2026-08-10 00:00:01"), level: .error, category: "c", message: "b"),
            SingBoxLogLine(timestamp: day("2026-08-10 12:00:00"), level: .warning, category: "c", message: "c"),
        ]

        let buckets = LogArchive.bucket(lines, fallback: day("2026-08-11 00:00:00"), timeZone: shanghai)

        #expect(Set(buckets.keys) == ["routebar-2026-08-09.log", "routebar-2026-08-10.log"])
        #expect(buckets["routebar-2026-08-10.log"]?.count == 2)
    }

    /// 启动失败那种 logrus 行没有时间戳，只能落到兜底日期——但不能被丢掉，
    /// 它恰恰是最要紧的一类。
    @Test func linesWithoutTimestampFallBackToTheGivenDay() {
        let line = SingBoxLogLine(timestamp: nil, level: .error, category: "sing-box", message: "bind failed")

        let buckets = LogArchive.bucket([line], fallback: day("2026-08-11 10:00:00"), timeZone: shanghai)

        #expect(buckets["routebar-2026-08-11.log"]?.count == 1)
    }

    /// 保留 N 天指的是「含今天在内的 N 天」，边界那天必须留着。
    @Test func expiresOnlyBeyondTheRetentionWindow() {
        let names = (5...11).map { "routebar-2026-08-\(String(format: "%02d", $0)).log" }
        let now = day("2026-08-11 09:00:00")

        let expired = LogArchive.expired(names, keeping: 3, now: now, timeZone: shanghai)

        // 保留 3 天 = 09、10、11，更早的全过期。
        #expect(Set(expired) == ["routebar-2026-08-05.log", "routebar-2026-08-06.log",
                                 "routebar-2026-08-07.log", "routebar-2026-08-08.log"])
    }

    /// 过期清理也要认旧名字，否则 1.15.0 留下的文件会永远留在盘上。
    @Test func expiryAlsoCoversLegacyFileNames() {
        let expired = LogArchive.expired(["singbox-2026-07-01.log"], keeping: 14,
                                         now: day("2026-08-11 09:00:00"), timeZone: shanghai)
        #expect(expired == ["singbox-2026-07-01.log"])
    }

    @Test func retentionOfZeroKeepsEverything() {
        let names = ["routebar-2020-01-01.log"]
        #expect(LogArchive.expired(names, keeping: 0, now: day("2026-08-11 09:00:00")).isEmpty)
    }

    /// 归档写出去的格式必须能被同一个解析器读回来，否则「能写不能读」，
    /// 而这种错误要等到用户去翻历史时才暴露。
    @Test func renderedLinesParseBackIdentically() throws {
        let original = SingBoxLogLine(timestamp: day("2026-08-11 09:20:01"),
                                      level: .error,
                                      category: "outbound/vless",
                                      message: "open connection to example.com:443: EOF")

        let restored = try #require(SingBoxLogParser.parse(SingBoxLogParser.render(original)))

        #expect(restored.level == original.level)
        #expect(restored.category == original.category)
        #expect(restored.message == original.message)
        #expect(restored.timestamp == original.timestamp)
    }

    /// 打了前缀的 RouteBar 行同样要能原样读回来——分类里有斜杠，正是解析器
    /// 用来切分类的那个字符。
    @Test func taggedRouteBarLinesParseBackIdentically() throws {
        let original = SingBoxLogLine(timestamp: day("2026-08-11 09:20:01"),
                                      level: .notice,
                                      category: LogArchive.tag(routeBarCategory: "订阅"),
                                      message: "已更新订阅「JSSR」：15 个节点")

        let restored = try #require(SingBoxLogParser.parse(SingBoxLogParser.render(original)))
        let untagged = LogArchive.untag(restored.category)

        #expect(untagged.category == "订阅")
        #expect(untagged.isRouteBar)
        #expect(restored.message == original.message)
        // notice 不能退化成 info：它标记的是「RouteBar 刚做了一件事」，
        // 掉级之后就淹在流水里了。
        #expect(restored.level == .notice)
    }

    /// 没有子系统名的那种（分类是兜底的 "sing-box"）不该在往返后凭空多出一个前缀。
    @Test func renderKeepsFallbackCategoryClean() throws {
        let original = SingBoxLogLine(timestamp: day("2026-08-11 09:20:01"),
                                      level: .warning, category: "sing-box", message: "something happened")

        let text = SingBoxLogParser.render(original)
        let restored = try #require(SingBoxLogParser.parse(text))

        #expect(!text.contains("sing-box:"))
        #expect(restored.category == "sing-box")
        #expect(restored.message == "something happened")
    }
}
