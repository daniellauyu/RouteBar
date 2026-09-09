import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 日志页：**唯一**一处诊断入口。
///
/// RouteBar 自己的记录（订阅更新、配置生成、服务控制、测速）与 sing-box 报出来的问题
/// 按时间混在一列里，用来源列区分。原来这两样分在两个页面，排查时要自己在脑子里
/// 把两条时间线对齐——而它们描述的是同一件事的两侧：RouteBar 说「配置装好了」，
/// sing-box 说「这个节点握手失败」，分开看谁也解释不了对方。
///
/// 读的是**按日期归档的文件**，不是内存缓冲。文件才是能跨重启活下来的那份记录，
/// 也已经带着好几天的历史；内存里再存一份只能显示这一次运行。
///
/// 筛选条件一律是「收窄」而不是「切换视图」：日期 → 时段 → 级别 → 来源 → 关键词，
/// 从左到右由粗到细，每一档都在上一档的结果里再筛。
struct LogView: View {
    @EnvironmentObject private var log: RuntimeLog
    @EnvironmentObject private var model: AppModel
    @State private var minLevel: LogLevel = .info
    @State private var timeFilter: LogTimeFilter = .allDay
    @State private var source: LogSource?
    @State private var searchText = ""

    /// 轮询间隔。够短，短到排查时不用怀疑「是没发生还是没刷新」；又不至于让一个
    /// 空转的循环显得频繁——没有新内容时这一轮只是 seek 到文件末尾比一下大小。
    private static let pollInterval = 3.0

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            if visibleEntries.isEmpty {
                ContentUnavailableView(
                    model.dayEntries.isEmpty ? "这一天没有日志" : "没有匹配的日志",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(model.dayEntries.isEmpty
                                      ? "RouteBar 的操作记录，以及 sing-box 报出来的问题，都会出现在这里。"
                                      : "放宽时段、级别或关键词试试。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                logList
            }
        }
        .task { await model.refreshLogDates() }
        // 这一页开着的时候才轮询，离开就随 task 一起取消。
        //
        // sing-box 的日志没有推送可言：那是 launchd 交给它的一个文件，只能自己去看
        // 有没有变长。原先只在启动、窗口重新激活和服务操作时读一次——盯着这一页等
        // 一条握手失败出现的人，永远等不到，得切走再切回来才看得见。
        .task {
            while !Task.isCancelled {
                await model.pollSingBoxLog()
                try? await Task.sleep(for: .seconds(Self.pollInterval))
            }
        }
    }

    // MARK: - 筛选栏

    private var controlBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: LogListLayout.controlSpacing) {
                FilterMenu(accessibilityLabel: "日期",
                           selection: $model.viewingDay,
                           options: model.logDates.map {
                               FilterMenuOption(value: $0, title: Self.dayTitle($0))
                           },
                           width: LogListLayout.datePickerWidth)

                FilterMenu(accessibilityLabel: "时段",
                           selection: $timeFilter,
                           options: LogTimeFilter.options.map {
                               FilterMenuOption(value: $0, title: $0.title)
                           },
                           width: LogListLayout.timePickerWidth)

                FilterMenu(accessibilityLabel: "级别",
                           selection: $minLevel,
                           options: LogLevel.allCases.map {
                               FilterMenuOption(value: $0, title: "≥ \($0.rawValue)")
                           },
                           width: LogListLayout.secondaryPickerWidth)

                FilterMenu(accessibilityLabel: "来源",
                           selection: $source,
                           options: [FilterMenuOption(value: LogSource?.none, title: "全部来源")]
                               + LogSource.allCases.map { FilterMenuOption(value: Optional($0), title: $0.rawValue) },
                           width: LogListLayout.secondaryPickerWidth)

                // 唯一可伸缩的控件，也**不设最小宽度**：窗口最窄（900）时它会被压到
                // 一百点上下，仍然能用；给了最小宽度反而会让整条筛选栏溢出、右边的
                // 按钮被裁掉——宁可搜索框窄一点，也不能有控件按不到。
                TextField("搜索日志", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: LogListLayout.searchMaximumWidth)
            }

            Spacer(minLength: LogListLayout.groupSpacing)

            HStack(spacing: LogListLayout.controlSpacing) {
                Text(countDescription)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                actionMenu
            }
            .controlSize(.small)
        }
        .padding(.horizontal, LogListLayout.horizontalInset)
        .padding(.vertical, LogListLayout.filterVerticalInset)
    }

    /// 复制、导出、打开文件夹、删除收进一颗菜单。
    ///
    /// 摊成五个图标按钮时，筛选栏在最小窗口（900）下会把搜索框挤成一条缝——实测过。
    /// 这几件事都是「看完之后」才做的，藏一层不影响主路径，而筛选是主路径。
    private var actionMenu: some View {
        Menu {
            Button("刷新", systemImage: "arrow.clockwise") {
                Task { await model.refreshLogDates() }
            }
            Divider()
            Button("复制当前结果", systemImage: "doc.on.doc") { copyVisible() }
                .disabled(visibleEntries.isEmpty)
            Button("导出当前结果…", systemImage: "square.and.arrow.up") { export() }
                .disabled(visibleEntries.isEmpty)
            Divider()
            Button("打开归档文件夹", systemImage: "folder") { model.revealLogArchive() }
            Button("删除这一天的归档", systemImage: "trash", role: .destructive) {
                model.deleteLog(model.viewingDay)
            }
            .disabled(model.dayEntries.isEmpty)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: LogListLayout.actionMenuWidth)
        .help("刷新、复制、导出、打开归档文件夹、删除")
    }

    // MARK: - 列表

    private var logList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // 最新的在最上面：出问题时要看的就是刚刚发生了什么。
                ForEach(visibleEntries.reversed()) { entry in
                    row(entry)
                    Divider().opacity(0.4)
                }
            }
            .padding(.vertical, 4)
            .textSelection(.enabled)
        }
    }

    private func row(_ entry: RuntimeLogEntry) -> some View {
        HStack(alignment: .top, spacing: LogListLayout.controlSpacing) {
            Image(systemName: entry.level.symbol)
                .font(.caption)
                .foregroundStyle(entry.level.tint)
                .frame(width: LogListLayout.levelColumn)
            Text(entry.timestamp, format: .dateTime.hour().minute().second())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: LogListLayout.timeColumn, alignment: .leading)
                .lineLimit(1)
            Text(entry.source.rawValue)
                .font(.caption2.weight(.medium))
                .foregroundStyle(entry.source == .singBox ? Color.purple : Color.secondary)
                .frame(width: LogListLayout.sourceColumn, alignment: .leading)
                .lineLimit(1)
            Text(entry.category)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: LogListLayout.categoryColumn, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)
            // 等宽：日志正文里全是地址、端口、耗时，比例字体下同类信息对不齐，
            // 一屏几十行时很难扫。换行而不是截断——错误原因往往在句子末尾。
            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, LogListLayout.horizontalInset)
        .padding(.vertical, 6)
    }

    // MARK: - 数据

    /// 筛完再**按时间排序**。
    ///
    /// 不能直接用文件里的先后：sing-box 那些行带的是它自己写日志时的时间戳，而 RouteBar
    /// 每隔几秒才去读一次文件，于是一批 09:49 的记录会在 09:51 才被追加进去，排在
    /// RouteBar 自己 09:51 的记录后面。一页号称按时间排的日志里出现时间倒挂，
    /// 排查时会把因果顺序看反。
    ///
    /// 同一秒内的多条保持原有先后（用下标兜底），否则每次重绘顺序都可能变。
    private var visibleEntries: [RuntimeLogEntry] {
        model.dayEntries.enumerated()
            .filter { _, entry in
                entry.level >= minLevel
                    && timeFilter.matches(entry.timestamp)
                    && (source == nil || entry.source == source)
                    && (searchText.isEmpty
                        || entry.message.localizedCaseInsensitiveContains(searchText)
                        || entry.category.localizedCaseInsensitiveContains(searchText))
            }
            .sorted { left, right in
                left.element.timestamp == right.element.timestamp
                    ? left.offset < right.offset
                    : left.element.timestamp < right.element.timestamp
            }
            .map(\.element)
    }

    /// 筛掉了多少也要说：只显示「120 条」的话，用户不知道自己是看全了还是被条件挡住了。
    private var countDescription: String {
        visibleEntries.count == model.dayEntries.count
            ? "\(model.dayEntries.count) 条"
            : "\(visibleEntries.count) / \(model.dayEntries.count) 条"
    }

    /// 最近两天用「今天 / 昨天」，更早的给日期加星期。
    ///
    /// 排查时看的九成是今天，而「8月11日」还要在脑子里换算一次才知道是不是今天。
    /// 不用 `doesRelativeDateFormatting`：那个开关只对 `dateStyle` 生效，一旦设了
    /// 自定义 `dateFormat` 就被静默忽略——写上去像是生效了，其实没有。
    private static func dayTitle(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        return dayFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEE"
        return formatter
    }()

    // MARK: - 导出

    private func copyVisible() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(log.exportText(visibleEntries), forType: .string)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText, .log]
        panel.nameFieldStringValue = "RouteBar-\(model.viewingDay.formatted(.iso8601.year().month().day())).log"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? log.exportText(visibleEntries).write(to: url, atomically: true, encoding: .utf8)
    }
}
