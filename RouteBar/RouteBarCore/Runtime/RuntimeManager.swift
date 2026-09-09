import os
import Foundation

/// sing-box 服务与托管文件的执行层。
public struct RuntimeManager: Sendable {
    public let paths: RuntimePaths
    private let runner: CommandRunner

    public nonisolated init(settings: RouteBarSettings = RouteBarSettings.defaults(),
                            runner: CommandRunner = CommandRunner()) {
        paths = RuntimePaths(settings: settings)
        self.runner = runner
    }

    // MARK: - 服务控制

    public nonisolated func status() async -> ServiceState {
        guard let result = try? await runner.run("/bin/launchctl", ["print", paths.launchctlTarget]) else {
            return .stopped
        }
        return LaunchCtlStatusParser.parse(exitCode: result.exitCode, output: result.output)
    }

    /// `kickstart -k`：已在跑就重启，没在跑就拉起来。启动与重启是同一条路径。
    ///
    /// plist 在盘上但没被 launchd 加载时（重装系统、手动 bootout、某次登录会话没接手），
    /// kickstart 会报 `Could not find service ... in domain for user gui: 501`。
    /// 这种情况下自己 bootstrap 一次再重试——把「去终端敲一行 launchctl bootstrap」
    /// 这件事收进按钮里，而不是把 launchctl 的原始报错甩给用户。
    public nonisolated func restart() async -> ServiceState {
        guard let result = try? await runner.run("/bin/launchctl", ["kickstart", "-k", paths.launchctlTarget]) else {
            return .failed("无法调用 launchctl")
        }
        if result.succeeded { return await confirmStarted() }
        guard LaunchCtlStatusParser.indicatesServiceNotLoaded(exitCode: result.exitCode, output: result.output) else {
            return .failed(result.output.trimmed())
        }
        return await bootstrapThenKickstart()
    }

    public nonisolated func stop() async -> ServiceState {
        guard let result = try? await runner.run("/bin/launchctl", ["bootout", paths.launchctlTarget]) else {
            return .failed("无法调用 launchctl")
        }
        if result.succeeded { return .stopped }
        // 没加载的服务本来就是停着的，报错没有意义。
        guard !LaunchCtlStatusParser.indicatesServiceNotLoaded(exitCode: result.exitCode, output: result.output) else {
            return .stopped
        }
        return .failed(result.output.trimmed())
    }

    /// 把盘上的 plist 重新 bootstrap 进 launchd，再拉起服务。
    ///
    /// 这里不重写 plist：文件可能是用户手写的（`launchAgentState() == .foreign`），
    /// 加载别人的文件是安全的，覆盖不是——覆盖仍然只走「环境」页那条要确认的路径。
    private nonisolated func bootstrapThenKickstart() async -> ServiceState {
        guard FileManager.default.fileExists(atPath: paths.launchAgent.path) else {
            return .failed("LaunchAgent 不存在：\(paths.launchAgent.path)，请先在「环境」页安装")
        }
        CoreLog.configuration.notice("服务未加载，重新 bootstrap：\(paths.label, privacy: .public)")
        let domain = "gui/\(paths.userID)"
        guard let bootstrap = try? await runner.run("/bin/launchctl",
                                                    ["bootstrap", domain, paths.launchAgent.path]) else {
            return .failed("无法调用 launchctl")
        }
        guard bootstrap.succeeded else {
            return .failed("重新加载 LaunchAgent 失败：\(bootstrap.output.trimmed())")
        }
        // bootstrap 是否顺带把进程拉起来取决于 plist 里的 RunAtLoad，不能假设。
        guard let kickstart = try? await runner.run("/bin/launchctl",
                                                    ["kickstart", "-k", paths.launchctlTarget]) else {
            return .failed("无法调用 launchctl")
        }
        guard kickstart.succeeded else { return .failed(kickstart.output.trimmed()) }
        CoreLog.configuration.notice("已重新加载并启动：\(paths.label, privacy: .public)")
        return await confirmStarted()
    }

    /// launchctl 接受启动请求不等于服务已稳定运行，给运行时错误一个暴露窗口。
    private nonisolated func confirmStarted() async -> ServiceState {
        var lastState: ServiceState = .stopped
        var consecutiveRunning = 0
        for _ in 0..<6 {
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { return .failed("启动状态检查已取消") }
            lastState = await status()
            consecutiveRunning = lastState.isRunning ? consecutiveRunning + 1 : 0
            if consecutiveRunning >= 3 { return lastState }
        }
        if case .failed = lastState { return lastState }
        return .failed("启动后未能确认 sing-box 持续运行，请检查错误日志和端口占用")
    }

    // MARK: - 安装

    /// 安装新配置：先让 sing-box 自己校验，通过后才覆盖正式文件。
    ///
    /// 顺序很关键——直接写正式配置再重启，配置有问题时服务会起不来，而旧配置已经没了，
    /// 代理直接全断。所以先写到 `routebar-next.json` 跑 `sing-box check`，
    /// 校验失败就原地抛错，正式配置一个字节都没动。
    public nonisolated func install(_ generated: GeneratedConfiguration) async throws {
        let candidate = paths.singBoxConfigDirectory.appendingPathComponent("routebar-next.json")
        try FileManager.default.createDirectory(at: paths.singBoxConfigDirectory, withIntermediateDirectories: true)
        try generated.singBoxJSON.write(to: candidate, options: .atomic)
        defer { try? FileManager.default.removeItem(at: candidate) }

        let check = try await runner.run(paths.singBoxBinary.path, ["check", "-c", candidate.path])
        guard check.succeeded else { throw InstallError.validation(check.output.trimmed()) }

        try backup(paths.singBoxConfig)
        try generated.singBoxJSON.write(to: paths.singBoxConfig, options: .atomic)
        CoreLog.configuration.notice("已安装 sing-box 配置：\(generated.nodes.count) 个节点")
    }

    /// 已安装的 sing-box 配置是否就是这一份。
    ///
    /// 用来回答「这次改动要不要重启服务」：只改了节点名的话，sing-box 那份 JSON 一个
    /// 字节都没变（名字只出现在给客户端的策略列表里），顺手重启等于白断一次全部连接。
    public nonisolated func installedSingBoxConfigMatches(_ generated: GeneratedConfiguration) -> Bool {
        (try? Data(contentsOf: paths.singBoxConfig)) == generated.singBoxJSON
    }

    // MARK: - LaunchAgent

    /// 当前 plist 与设置的关系，决定「环境」页给出什么操作。
    public nonisolated func launchAgentState() -> LaunchAgentState {
        guard let existing = try? Data(contentsOf: paths.launchAgent) else { return .missing }
        guard LaunchAgentDefinition.isManaged(existing) else { return .foreign }
        let expected = try? LaunchAgentDefinition(settings: paths.settings).propertyListData()
        return existing == expected ? .managedUpToDate : .managedOutdated
    }

    /// 预览将要写入的 plist，供用户覆盖前过目。
    public nonisolated func launchAgentPreview() throws -> String {
        let data = try LaunchAgentDefinition(settings: paths.settings).propertyListData()
        return String(decoding: data, as: UTF8.self)
    }

    /// 写出 plist 并交给 launchd。
    ///
    /// `allowOverwritingForeignFile` 必须由调用方在用户看过内容并确认后才置为真：
    /// 用户手写的 plist 里可能有 RouteBar 不知道的字段（代理环境变量、Nice 值、
    /// 资源限制），静默覆盖等于悄悄改掉他的服务配置。
    public nonisolated func installLaunchAgent(allowOverwritingForeignFile: Bool = false) async throws {
        let state = launchAgentState()
        if state == .foreign, !allowOverwritingForeignFile {
            throw InstallError.foreignLaunchAgent(paths.launchAgent.path)
        }
        guard state != .managedUpToDate else { return }

        let data = try LaunchAgentDefinition(settings: paths.settings).propertyListData()
        try FileManager.default.createDirectory(at: paths.launchAgent.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try backup(paths.launchAgent)
        try data.write(to: paths.launchAgent, options: .atomic)

        // 先 bootout 再 bootstrap：plist 改了但服务已加载时，launchd 不会自动重读，
        // bootstrap 会直接报「service already loaded」而旧定义继续生效。
        // 没加载过时 bootout 返回非零，属正常，忽略即可。
        _ = try? await runner.run("/bin/launchctl", ["bootout", paths.launchctlTarget])
        let domain = "gui/\(paths.userID)"
        let result = try await runner.run("/bin/launchctl", ["bootstrap", domain, paths.launchAgent.path])
        guard result.succeeded else { throw InstallError.launchAgentLoad(result.output.trimmed()) }
        CoreLog.configuration.notice("已安装 LaunchAgent：\(paths.label, privacy: .public)")
    }

    /// 覆盖前留一份 `.routebar-backup`，手工回滚时有东西可用。
    private nonisolated func backup(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let backup = url.appendingPathExtension("routebar-backup")
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.copyItem(at: url, to: backup)
    }

    /// 创建 RouteBar 需要写入的目录（sing-box 配置目录、LaunchAgents）。
    public nonisolated func createRequiredDirectories() throws {
        try FileManager.default.createDirectory(at: paths.singBoxConfigDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.launchAgent.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
    }

    /// 读日志文件末尾若干字节。
    ///
    /// 用 `FileHandle` 定位到末尾再往回读，**不能**用 `Data(contentsOf:)` 再 `suffix`——
    /// 那样每刷新一次就把整个文件读进内存，而这份文件实测能长到 65 MB，
    /// 而且窗口每次激活、每次服务操作都会刷新一遍。注释说着「避免整个读进内存」，
    /// 代码却恰恰是那么干的。
    public nonisolated func tail(_ url: URL, limit: Int = 20_000) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "暂无日志：\(url.path)" }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return "暂无日志：\(url.path)" }
        let start = size > UInt64(limit) ? size - UInt64(limit) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else {
            return "暂无日志：\(url.path)"
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// 从上次读到的位置继续往下读，用于把 sing-box 的新日志增量并进日志页。
    ///
    /// 按字节偏移续读而不是「比对上次那一行」：日志里大量行是逐字重复的
    /// （同一个目标反复失败），靠文本找位置必然会重复或漏掉一整段。
    ///
    /// 返回的偏移要原样交回下一次调用。文件被清空或换掉时（`size < offset`）从头开始。
    public nonisolated func readNewLines(of url: URL, from offset: UInt64,
                                         firstReadLimit: Int = 20_000) -> (text: String, offset: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ("", 0) }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return ("", offset) }
        // 首次读取（offset == 0）不把历史全灌进来：那可能是几十万行。只取末尾一小段。
        var start = offset
        if offset == 0, size > UInt64(firstReadLimit) {
            start = size - UInt64(firstReadLimit)
        } else if size < offset {
            start = 0
        }
        guard start < size else { return ("", start) }
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.read(upToCount: 1_048_576) else { return ("", offset) }
        // 按实际读到的完整行推进。文件增长不能让旧 size 成为下轮游标，
        // 尾部半行也必须留到下次，否则会丢失被分两次写入的日志。
        guard let newline = data.lastIndex(of: 0x0A) else { return ("", start) }
        let consumed = data.distance(from: data.startIndex, to: newline) + 1
        var complete = data.prefix(consumed)
        if start > 0, offset == 0, let firstNewline = complete.firstIndex(of: 0x0A) {
            complete = complete.suffix(from: complete.index(after: firstNewline))
        }
        return (String(decoding: complete, as: UTF8.self), start + UInt64(consumed))
    }

    /// 清空 sing-box 的两份日志。
    ///
    /// 截断而不是删除：文件是 launchd 按 plist 里的路径打开的，删掉之后
    /// sing-box 仍然握着那个已经不在目录里的 inode 继续写，磁盘一点没省下来。
    public nonisolated func clearLogs() throws {
        for url in [paths.singBoxLog, paths.singBoxErrorLog] {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 0)
            try handle.close()
        }
    }

    public enum InstallError: LocalizedError {
        case validation(String)
        case foreignLaunchAgent(String)
        case launchAgentLoad(String)

        public var errorDescription: String? {
            switch self {
            case .validation(let output): "sing-box 配置校验失败：\(output)"
            case .foreignLaunchAgent(let path): "\(path) 不是 RouteBar 创建的，需要确认后才能覆盖"
            case .launchAgentLoad(let output): "launchctl 加载失败：\(output)"
            }
        }
    }
}

extension String {
    nonisolated func trimmed() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
