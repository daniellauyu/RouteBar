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
    public nonisolated func install(_ generated: GeneratedConfiguration) async throws {
        let candidate = paths.singBoxConfigDirectory.appendingPathComponent("routebar-next.json")
        try FileManager.default.createDirectory(at: paths.singBoxConfigDirectory, withIntermediateDirectories: true)
        try generated.singBoxJSON.write(to: candidate, options: .atomic)
        defer { try? FileManager.default.removeItem(at: candidate) }

        let check = try await runner.run(paths.singBoxBinary.path, ["check", "-c", candidate.path])
        guard check.succeeded else { throw InstallError.validation(check.output.trimmed()) }

        try backup(paths.singBoxConfig)
        try generated.singBoxJSON.write(to: paths.singBoxConfig, options: .atomic)

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

    /// sing-box JSON 与 Surge 托管段都已经是目标内容时，不再校验、覆盖或重启。
    public nonisolated func installedConfigurationMatches(_ generated: GeneratedConfiguration) -> Bool {
        guard let installedJSON = try? Data(contentsOf: paths.singBoxConfig),
              installedJSON == generated.singBoxJSON,
              let profile = try? String(contentsOf: paths.surgeProfile, encoding: .utf8),
              let updatedProfile = try? SurgeProfileUpdater.update(profile, with: generated) else {
            return false
        }
        return updatedProfile == profile
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

        public var errorDescription: String? {
            switch self {
            case .validation(let output): "sing-box 配置校验失败：\(output)"
            case .missingSurgeProfile(let path): "Surge 托管配置不存在：\(path)"
            }
        }
    }
}

extension String {
    nonisolated func trimmed() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
