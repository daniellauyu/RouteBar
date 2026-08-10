import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 运行日志页：**唯一**一处诊断入口。
///
/// RouteBar 自己的记录（订阅更新、配置生成、服务控制、测速）与 sing-box 报出来的问题
/// 按时间混在一列里，用来源列区分。原来这两样分在两个页面，排查时要自己在脑子里
/// 把两条时间线对齐——而它们描述的是同一件事的两侧：RouteBar 说「配置装好了」，
/// sing-box 说「这个节点握手失败」，分开看谁也解释不了对方。
struct LogView: View {
    @EnvironmentObject private var log: RuntimeLog
    @State private var minLevel: LogLevel = .info
    @State private var source: LogSource?
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            if visibleEntries.isEmpty {
                ContentUnavailableView(
                    log.entries.isEmpty ? "暂无运行日志" : "没有匹配的日志",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(log.entries.isEmpty
                                      ? "RouteBar 的操作记录，以及 sing-box 报出来的问题，都会出现在这里。"
                                      : "调整级别、来源或搜索条件试试。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                logList
            }
        }
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Picker("级别", selection: $minLevel) {
                ForEach(LogLevel.allCases) { level in
                    Text("≥ \(level.rawValue)").tag(level)
                }
            }
            .labelsHidden()
            .frame(width: 120)

            Picker("来源", selection: $source) {
                Text("全部来源").tag(LogSource?.none)
                ForEach(LogSource.allCases) { Text($0.rawValue).tag(Optional($0)) }
            }
            .labelsHidden()
            .frame(width: 120)

            TextField("搜索日志", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)

            Spacer()

            Text("\(visibleEntries.count) 条")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("复制", systemImage: "doc.on.doc") { copyAll() }
                .disabled(visibleEntries.isEmpty)
            Button("导出", systemImage: "square.and.arrow.up") { export() }
                .disabled(visibleEntries.isEmpty)
            Button("清空", systemImage: "trash", role: .destructive) { log.clear() }
                .disabled(log.entries.isEmpty)
        }
        .controlSize(.small)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var logList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // 最新的在最上面：出问题时要看的就是刚刚发生了什么。
                ForEach(visibleEntries.reversed()) { entry in
                    row(entry)
                    Divider()
                }
            }
            .padding(.vertical, 4)
            .textSelection(.enabled)
        }
    }

    private func row(_ entry: RuntimeLogEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.level.symbol)
                .foregroundStyle(entry.level.tint)
                .frame(width: 18)
            Text(entry.timestamp, format: .dateTime.hour().minute().second())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(entry.source.rawValue)
                .font(.caption2.weight(.medium))
                .foregroundStyle(entry.source == .singBox ? Color.purple : Color.secondary)
                .frame(width: 58, alignment: .leading)
            Text(entry.category)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(entry.message)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
    }

    private var visibleEntries: [RuntimeLogEntry] {
        log.entries.filter { entry in
            entry.level >= minLevel
                && (source == nil || entry.source == source)
                && (searchText.isEmpty
                    || entry.message.localizedCaseInsensitiveContains(searchText)
                    || entry.category.localizedCaseInsensitiveContains(searchText))
        }
    }

    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(log.exportText(visibleEntries), forType: .string)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText, .log]
        panel.nameFieldStringValue = "RouteBar-\(Date().formatted(.iso8601.year().month().day())).log"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? log.exportText(visibleEntries).write(to: url, atomically: true, encoding: .utf8)
    }
}
