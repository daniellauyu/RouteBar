import Foundation

/// 按日期归档日志的命名、分桶与来源标注规则。
///
/// 为什么归档要由 RouteBar 来做：sing-box 那份日志是 **launchd** 按 plist 里的固定路径
/// 打开、当作 fd 2 交给它的。sing-box 自己不做轮转，而改名也没用——进程握着的是 inode，
/// 改完名它照样往同一个文件写，只是新名字。想按日期分开，只能由 RouteBar 把读到的内容
/// 抄进自己的日期文件里。
///
/// 归档里**两种来源都有**：sing-box 报的问题，以及 RouteBar 自己做了什么。少了后者的话，
/// 在日志页选「今天」会看不到订阅更新、配置生成、服务控制这些事件——而排查时要看的恰恰
/// 是这两条时间线怎么对上。
///
/// 纯字符串与日期计算，所以放 Domain：分桶分错、过期算错都是安静的数据丢失，
/// 必须能用测试钉住。
public enum LogArchive {
    public nonisolated static let filePrefix = "routebar-"
    public nonisolated static let fileExtension = "log"

    /// 1.15.0 那版归档只存 sing-box，文件名叫 `singbox-`。仍然认它，否则升级当天
    /// 之前的记录会从日期列表里凭空消失（文件还在盘上，只是没人认领）。只读不写。
    public nonisolated static let legacyFilePrefix = "singbox-"

    /// RouteBar 自己那条记录的分类前缀。
    ///
    /// 来源不另开一列存，而是借分类名区分：归档行沿用 sing-box 的行格式，多加一个字段
    /// 就得自己维护一套读写规则。sing-box 的分类是 `outbound/vless`、`connection` 这些，
    /// 它永远不会写出 `routebar/`，所以拿这个前缀当标记不会撞。
    public nonisolated static let routeBarCategoryPrefix = "routebar/"

    /// 归档文件名。`routebar-2026-08-11.log`
    public nonisolated static func fileName(for date: Date, timeZone: TimeZone = .current) -> String {
        "\(filePrefix)\(dayFormatter(timeZone).string(from: date)).\(fileExtension)"
    }

    /// 从文件名反推日期。不是归档文件就返回 nil——目录里可能有别的东西，不能瞎猜。
    public nonisolated static func date(fromFileName name: String, timeZone: TimeZone = .current) -> Date? {
        guard name.hasSuffix(".\(fileExtension)") else { return nil }
        let prefix = [filePrefix, legacyFilePrefix].first { name.hasPrefix($0) }
        guard let prefix else { return nil }
        let day = name.dropFirst(prefix.count).dropLast(fileExtension.count + 1)
        return dayFormatter(timeZone).date(from: String(day))
    }

    /// 同一天可能同时存在新旧两个文件名，按新的在前返回，读的时候两份都要拼进来。
    public nonisolated static func fileNames(for date: Date, timeZone: TimeZone = .current) -> [String] {
        let day = dayFormatter(timeZone).string(from: date)
        return [filePrefix, legacyFilePrefix].map { "\($0)\(day).\(fileExtension)" }
    }

    // MARK: - 来源标注

    /// 写进归档前，把 RouteBar 自己的分类打上前缀。
    public nonisolated static func tag(routeBarCategory category: String) -> String {
        routeBarCategoryPrefix + category
    }

    /// 读回来时剥掉前缀，并说明这一行是谁写的。
    public nonisolated static func untag(_ category: String) -> (category: String, isRouteBar: Bool) {
        guard category.hasPrefix(routeBarCategoryPrefix) else { return (category, false) }
        return (String(category.dropFirst(routeBarCategoryPrefix.count)), true)
    }

    // MARK: - 分桶与过期

    /// 按**每一行自己的时间戳**分桶，而不是一律算作「今天」。
    ///
    /// RouteBar 不是常驻的：它关着的时候 sing-box 照样写日志，下次启动一口气读到的
    /// 可能横跨好几天。按当天归档会把那几天的记录全堆进一个文件，日期也就没有意义了。
    /// 没有时间戳的行（启动失败那种 logrus 格式）落到 `fallback`。
    public nonisolated static func bucket(_ lines: [SingBoxLogLine],
                                          fallback: Date,
                                          timeZone: TimeZone = .current) -> [String: [SingBoxLogLine]] {
        Dictionary(grouping: lines) { fileName(for: $0.timestamp ?? fallback, timeZone: timeZone) }
    }

    /// 超过保留期、该删掉的那些文件名。
    ///
    /// 按**日期**比而不是按文件修改时间：修改时间会被备份、同步、随手打开改掉，
    /// 而文件名里的日期是这份内容自己的属性，不会因为碰了一下就变。
    public nonisolated static func expired(_ names: [String],
                                           keeping days: Int,
                                           now: Date,
                                           timeZone: TimeZone = .current) -> [String] {
        guard days > 0 else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        guard let cutoff = calendar.date(byAdding: .day, value: -(days - 1), to: today) else { return [] }
        return names.filter { name in
            guard let date = date(fromFileName: name, timeZone: timeZone) else { return false }
            return date < cutoff
        }
    }

    private nonisolated static func dayFormatter(_ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}
