import Foundation
import Testing
@testable import RouteBarDomain

@Suite struct LogTimeFilterTests {
    private var shanghai: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func moment(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text)!
    }

    @Test func allDayKeepsEverything() {
        #expect(LogTimeFilter.allDay.matches(moment("2026-08-11 03:00:00"), calendar: shanghai))
        #expect(LogTimeFilter.allDay.matches(moment("2026-08-11 23:59:59"), calendar: shanghai))
    }

    /// 时段左闭右开，相邻两档不能同时命中同一条——重叠的话同一行会在两个时段里
    /// 各出现一次，数量对不上。
    @Test func hourBlocksDoNotOverlap() {
        let noon = moment("2026-08-11 12:00:00")

        #expect(!LogTimeFilter.hours(from: 6, to: 12).matches(noon, calendar: shanghai))
        #expect(LogTimeFilter.hours(from: 12, to: 18).matches(noon, calendar: shanghai))
    }

    /// 四档必须刚好铺满一天：任意时刻有且只有一档命中，否则某个钟点的日志
    /// 无论怎么选都看不到。
    @Test func hourBlocksCoverEveryHourExactlyOnce() {
        let blocks = LogTimeFilter.options.filter { $0 != .allDay }

        for hour in 0..<24 {
            let moment = moment(String(format: "2026-08-11 %02d:30:00", hour))
            let hits = blocks.filter { $0.matches(moment, calendar: shanghai) }
            #expect(hits.count == 1, "\(hour) 点命中了 \(hits.count) 档")
        }
    }

    /// 时段只看小时数，于是换个时区同一条会落进不同的档——日历必须一路传下去，
    /// 不能在深处各自取默认值。
    @Test func hourBlocksFollowTheGivenCalendar() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let moment = moment("2026-08-11 02:00:00")  // UTC 时是前一天 18:00

        #expect(LogTimeFilter.hours(from: 0, to: 6).matches(moment, calendar: shanghai))
        #expect(LogTimeFilter.hours(from: 18, to: 24).matches(moment, calendar: utc))
    }

    /// 「全天」是默认值，不在列表首位的话选择器打开时会显示成空的。
    @Test func optionsStartWithAllDay() {
        #expect(LogTimeFilter.options.first == .allDay)
    }

    @Test func titlesReadAsTimeSpans() {
        #expect(LogTimeFilter.allDay.title == "全天")
        #expect(LogTimeFilter.hours(from: 6, to: 12).title == "06:00 – 12:00")
    }

    /// 标题当 id 用，重复的话 SwiftUI 的列表会认错行。
    @Test func optionIdentifiersAreUnique() {
        let ids = LogTimeFilter.options.map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}
