import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 运行日志页：RouteBar 自身的诊断记录（订阅更新、配置生成、服务控制、测速）。
///
/// 与「服务」页里的 sing-box 日志是两回事：那边是 sing-box 进程写的文件，
/// 这边是 RouteBar 做了什么。两者分开，排查时才知道该看哪一份。
struct LogView: View {
    @EnvironmentObject private var log: RuntimeLog
    @State private var minLevel: LogLevel = .info
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
                                      ? "订阅更新、配置生成、服务控制等事件会记录在这里。"
                                      : "调整级别或搜索条件试试。")
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
            Text(entry.category)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
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
