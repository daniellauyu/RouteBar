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
    public nonisolated func restart() async -> ServiceState {
        guard let result = try? await runner.run("/bin/launchctl", ["kickstart", "-k", paths.launchctlTarget]) else {
            return .failed("无法调用 launchctl")
        }
        return result.succeeded ? .running : .failed(result.output.trimmed())
    }

    public nonisolated func stop() async -> ServiceState {
        guard let result = try? await runner.run("/bin/launchctl", ["bootout", paths.launchctlTarget]) else {
            return .failed("无法调用 launchctl")
        }
        return result.succeeded ? .stopped : .failed(result.output.trimmed())
    }

    // MARK: - 安装

    /// 安装新配置：先让 sing-box 自己校验，通过后才覆盖正式文件。
    ///
    /// 顺序很关键——直接写正式配置再重启，配置有问题时服务会起不来，而旧配置已经没了，
    /// 代理直接全断。所以先写到 `routebar-next.json` 跑 `sing-box check`，
    /// 校验失败就原地抛错，正式配置一个字节都没动。
    public nonisolated func install(_ generated: GeneratedConfiguration,
                                    writesSurgeProfile: Bool = true) async throws {
        let candidate = paths.singBoxConfigDirectory.appendingPathComponent("routebar-next.json")
        try FileManager.default.createDirectory(at: paths.singBoxConfigDirectory, withIntermediateDirectories: true)
        try generated.singBoxJSON.write(to: candidate, options: .atomic)
        defer { try? FileManager.default.removeItem(at: candidate) }

        let check = try await runner.run(paths.singBoxBinary.path, ["check", "-c", candidate.path])
        guard check.succeeded else { throw InstallError.validation(check.output.trimmed()) }

        try backup(paths.singBoxConfig)
        try generated.singBoxJSON.write(to: paths.singBoxConfig, options: .atomic)

        // 只输出本地订阅地址时不碰 Surge 配置——那正是这个模式的意义所在：
        // `[Proxy]` 段是整段替换的，不写它才能和 sub.store 之类的外部订阅共存。
        guard writesSurgeProfile else {
            CoreLog.configuration.notice("已安装 sing-box 配置：\(generated.nodes.count) 个节点（Surge 走本地订阅）")
            return
        }

        let surgeURL = paths.surgeProfile
        guard FileManager.default.fileExists(atPath: surgeURL.path) else {
            throw InstallError.missingSurgeProfile(surgeURL.path)
        }
        let profile = try String(contentsOf: surgeURL, encoding: .utf8)
        let updated = try SurgeProfileUpdater.update(profile, with: generated)
        try backup(surgeURL)
        try Data(updated.utf8).write(to: surgeURL, options: .atomic)
        CoreLog.configuration.notice("已安装配置：\(generated.nodes.count) 个节点")
    }

    /// sing-box JSON 与（需要时）Surge 托管段都已经是目标内容时，不再校验、覆盖或重启。
    public nonisolated func installedConfigurationMatches(_ generated: GeneratedConfiguration,
                                                          writesSurgeProfile: Bool = true) -> Bool {
        guard let installedJSON = try? Data(contentsOf: paths.singBoxConfig),
              installedJSON == generated.singBoxJSON else { return false }
        guard writesSurgeProfile else { return true }
        guard let profile = try? String(contentsOf: paths.surgeProfile, encoding: .utf8),
              let updatedProfile = try? SurgeProfileUpdater.update(profile, with: generated) else {
            return false
        }
        return updatedProfile == profile
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

    /// 读日志文件末尾若干字节，避免把几十 MB 的日志整个读进内存。
    public nonisolated func tail(_ url: URL, limit: Int = 20_000) -> String {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return "暂无日志：\(url.path)" }
        let suffix = data.count > limit ? data.suffix(limit) : data[...]
        return String(decoding: suffix, as: UTF8.self)
    }

    public enum InstallError: LocalizedError {
        case validation(String)
        case missingSurgeProfile(String)
        case foreignLaunchAgent(String)
        case launchAgentLoad(String)

        public var errorDescription: String? {
            switch self {
            case .validation(let output): "sing-box 配置校验失败：\(output)"
            case .missingSurgeProfile(let path): "Surge 托管配置不存在：\(path)"
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
