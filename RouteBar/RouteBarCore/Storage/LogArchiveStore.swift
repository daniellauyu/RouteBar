import os
import Foundation

/// sing-box 日志的按日期归档。
///
/// 落点在 RouteBar 自己的目录（`~/Library/Application Support/RouteBar/logs/`）而不是
/// sing-box 那边：那份文件由 launchd 持有，RouteBar 只能读，动不了它的名字和位置。
/// 归档是 RouteBar 抄过来的副本，所以放在它自己管得住的地方，卸载时也跟着一起删。
public struct LogArchiveStore: Sendable {
    /// 保留天数。两周足够回溯「上周开始变慢」这类问题，又不至于把目录堆起来。
    public nonisolated static let retentionDays = 14

    public let directory: URL

    public nonisolated init(directory: URL? = nil) {
        self.directory = directory
            ?? RuntimePaths().appSupportDirectory.appendingPathComponent("logs", isDirectory: true)
    }

    /// 把新读到的行按各自日期追加进对应文件。
    public nonisolated func append(_ lines: [SingBoxLogLine], now: Date = .now) throws {
        guard !lines.isEmpty else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, bucket) in LogArchive.bucket(lines, fallback: now) {
            let text = bucket.map(SingBoxLogParser.render).joined(separator: "\n") + "\n"
            try appendText(text, to: directory.appendingPathComponent(name))
        }
    }

    /// 已有归档的日期，新的在前。同一天存在新旧两个文件名时只算一次。
    public nonisolated func availableDates() -> [Date] {
        Array(Set(fileNames().compactMap { LogArchive.date(fromFileName: $0) })).sorted(by: >)
    }

    /// 读某一天的归档。
    ///
    /// 新旧两个文件名都读进来再按时间排：1.15.0 那版写的是 `singbox-`，升级当天
    /// 同一天会有两个文件，只读其中一个的话那天只显示一半。
    ///
    /// `limit` 是**行数**上限，从末尾取：某一天可能有几十万行，整份塞进界面会直接卡死。
    public nonisolated func read(_ date: Date, limit: Int = 5_000) -> [SingBoxLogLine] {
        guard limit > 0 else { return [] }
        let lines = LogArchive.fileNames(for: date)
            .flatMap { tailLines(directory.appendingPathComponent($0), limit: limit) }
            .compactMap { SingBoxLogParser.parse(String($0)) }
        // 先按时间排再截断。两份文件是首尾相接读进来的，直接取末尾会把后一份的开头
        // 当成「最新」，而丢掉的可能恰恰是当天最后发生的事。没有时间戳的（启动失败
        // 那种）当作最新保留——它是最要紧的一类，不能被截掉。
        return lines
            .enumerated()
            .sorted { left, right in
                let l = left.element.timestamp ?? .distantFuture
                let r = right.element.timestamp ?? .distantFuture
                return l == r ? left.offset < right.offset : l < r
            }
            .suffix(limit)
            .map(\.element)
    }

    /// 从后往前按块读取，只解析末尾需要的行；超长单行也受 8 MB 上限约束。
    private nonisolated func tailLines(_ url: URL, limit: Int) -> [Substring] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard var position = try? handle.seekToEnd() else { return [] }
        var chunks: [Data] = []
        var bytes = 0
        var newlines = 0
        let byteLimit = 8 * 1024 * 1024
        while position > 0, newlines <= limit, bytes < byteLimit {
            let count = min(64 * 1024, Int(min(position, UInt64(byteLimit - bytes))))
            position -= UInt64(count)
            guard (try? handle.seek(toOffset: position)) != nil,
                  let chunk = try? handle.read(upToCount: count), !chunk.isEmpty else { break }
            chunks.append(chunk)
            bytes += chunk.count
            newlines += chunk.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        }
        var data = Data()
        data.reserveCapacity(bytes)
        for chunk in chunks.reversed() { data.append(chunk) }
        // 起点在文件中间时，首段可能是半行，不能当作独立日志解析。
        if position > 0 {
            guard let newline = data.firstIndex(of: 0x0A) else { return [] }
            data.removeSubrange(...newline)
        }
        return Array(String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true).suffix(limit))
    }

    /// 删掉超过保留期的归档。
    @discardableResult
    public nonisolated func prune(now: Date = .now) -> Int {
        let expired = LogArchive.expired(fileNames(), keeping: Self.retentionDays, now: now)
        for name in expired {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        if !expired.isEmpty {
            CoreLog.configuration.notice("已清理 \(expired.count) 份过期日志归档")
        }
        return expired.count
    }

    /// sing-box 日志已经归档到哪个字节。
    ///
    /// 必须跨启动记住。只放在内存里的话，每次启动都会从头（实际是末尾 20 KB）重读一遍，
    /// 把同一批行再归档一次——重启五次，那天的错误就在归档里出现五遍。实测过。
    private nonisolated var offsetURL: URL { directory.appendingPathComponent("ingest-offset") }

    public nonisolated func loadIngestOffset() -> UInt64 {
        guard let text = try? String(contentsOf: offsetURL, encoding: .utf8) else { return 0 }
        return UInt64(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    public nonisolated func saveIngestOffset(_ offset: UInt64) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(String(offset).utf8).write(to: offsetURL, options: .atomic)
    }

    /// 删掉某一天的归档（新旧两个文件名都删）。返回是否真的删掉了东西。
    @discardableResult
    public nonisolated func delete(_ date: Date) -> Bool {
        LogArchive.fileNames(for: date).reduce(into: false) { removed, name in
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            removed = (try? FileManager.default.removeItem(at: url)) != nil || removed
        }
    }

    public nonisolated func totalSize() -> Int64 {
        fileNames().reduce(into: Int64(0)) { total, name in
            let url = directory.appendingPathComponent(name)
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private nonisolated func fileNames() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    /// 追加而不是整份重写：同一天里 RouteBar 会写很多次，每次都重写会把当天的量
    /// 变成平方级的 I/O。文件不存在时先建。
    private nonisolated func appendText(_ text: String, to url: URL) throws {
        let data = Data(text.utf8)
        guard FileManager.default.fileExists(atPath: url.path) else {
            try data.write(to: url, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
