import Foundation

/// 本地状态与设置的读写（`~/Library/Application Support/RouteBar/`）。
///
/// 只存元数据、节点和设置——订阅 URL 在钥匙串（见 `KeychainStore`）。
public struct StateStore: Sendable {
    public let rootURL: URL

    public nonisolated init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        rootURL = home.appendingPathComponent("Library/Application Support/RouteBar", isDirectory: true)
    }

    public nonisolated var stateURL: URL { rootURL.appendingPathComponent("state.json") }
    public nonisolated var settingsURL: URL { rootURL.appendingPathComponent("settings.json") }
    public nonisolated var singBoxURL: URL { rootURL.appendingPathComponent("sing-box.json") }
    public nonisolated var surgeSnippetURL: URL { rootURL.appendingPathComponent("surge-proxies.conf") }

    // MARK: - 状态

    /// 读不出来一律回落到空状态：首次启动、文件损坏、格式变更都走这一条路，
    /// 应用永远能起来，大不了重新添加订阅。
    public nonisolated func load() -> RouteBarState {
        guard let data = try? Data(contentsOf: stateURL) else { return RouteBarState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(RouteBarState.self, from: data)) ?? RouteBarState()
    }

    public nonisolated func save(_ state: RouteBarState) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    // MARK: - 设置

    /// 用户是否配置过环境。为假时引擎会去接管机器上已有的 sing-box 服务（见 `LaunchAgentDiscovery`）。
    public nonisolated var hasStoredSettings: Bool {
        FileManager.default.fileExists(atPath: settingsURL.path)
    }

    public nonisolated func loadSettings() -> RouteBarSettings {
        guard let data = try? Data(contentsOf: settingsURL) else { return RouteBarSettings.defaults() }
        return (try? JSONDecoder().decode(RouteBarSettings.self, from: data)) ?? RouteBarSettings.defaults()
    }

    /// 扫描 `~/Library/LaunchAgents` 下的 plist，交给 `LaunchAgentDiscovery` 判断。
    public nonisolated func launchAgentPlists(home: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> [(path: String, data: Data)] {
        let directory = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.sorted()
            .filter { $0.hasSuffix(".plist") }
            .compactMap { name in
                let url = directory.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url) else { return nil }
                return (url.path, data)
            }
    }

    public nonisolated func saveSettings(_ settings: RouteBarSettings) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: settingsURL, options: .atomic)
    }

    // MARK: - 生成副本

    /// 在应用目录留一份生成结果，便于对照排查「装进去的到底是什么」。
    public nonisolated func saveGenerated(_ generated: GeneratedConfiguration) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try generated.singBoxJSON.write(to: singBoxURL, options: .atomic)
        try Data(generated.surgeProxySection.utf8).write(to: surgeSnippetURL, options: .atomic)
    }
}
