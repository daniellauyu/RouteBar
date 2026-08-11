import Foundation

/// 日志页在选中的那一天里再切一刀。
///
/// 日期选择器只能把范围缩到「一天」，而一天可能有几万行。真实的排查场景是
/// 「大概下午三点开始连不上」——需要在一天之内再定位到几点。
///
/// 刻度是当天的固定时段而不是「最近 N 分钟」：日志页看的永远是某一天的归档，
/// 翻昨天的记录时「最近一小时」没有意义（那天早就过去了），而「那天下午」有。
public enum LogTimeFilter: Hashable, Sendable, Identifiable {
    /// 不筛，整天。
    case allDay
    /// 当天的 `from..<to` 点。
    case hours(from: Int, to: Int)

    public var id: String { title }

    public var title: String {
        switch self {
        case .allDay: "全天"
        case .hours(let from, let to): String(format: "%02d:00 – %02d:00", from, to)
        }
    }

    /// 可选的刻度。第一项永远是「全天」，作为默认值。
    ///
    /// 六小时一档而不是逐小时：二十四个选项要在下拉里滚，而排查时人记得的是
    /// 「上午」「下午」这种粗粒度，真要精确到分钟有搜索框。
    public nonisolated static let options: [LogTimeFilter] = [
        .allDay,
        .hours(from: 0, to: 6),
        .hours(from: 6, to: 12),
        .hours(from: 12, to: 18),
        .hours(from: 18, to: 24),
    ]

    public nonisolated func matches(_ timestamp: Date, calendar: Calendar = .current) -> Bool {
        switch self {
        case .allDay:
            return true
        case .hours(let from, let to):
            let hour = calendar.component(.hour, from: timestamp)
            return hour >= from && hour < to
        }
    }
}
