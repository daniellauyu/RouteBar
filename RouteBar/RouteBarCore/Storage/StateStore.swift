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
    /// 命名脚本。
    ///
    /// 单独一个文件而不是塞进 settings.json：脚本动辄几百行，塞进去会让那份本来
    /// 一眼能看完的配置变得没法读，而且 JSON 里的换行全成了 `\n`，出问题时想用
    /// 别的编辑器打开看一眼都做不到。放成 .js 还能直接丢给编辑器和 lint。
    public nonisolated var namingScriptURL: URL { rootURL.appendingPathComponent("naming-script.js") }

    // MARK: - 命名脚本

    /// 读脚本。没写过时返回空串——空脚本在上层等同于「没配」，会回落到规范化。
    public nonisolated func loadNamingScript() throws -> String {
        guard let data = try readIfPresent(namingScriptURL) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    public nonisolated func saveNamingScript(_ script: String) throws {
        try writePrivate(Data(script.utf8), to: namingScriptURL)
    }

    // MARK: - 状态

    /// 只有首次启动（文件不存在）回落默认值；损坏或读取失败不能伪装为空状态。
    public nonisolated func load() throws -> RouteBarState {
        guard let data = try readIfPresent(stateURL) else { return RouteBarState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RouteBarState.self, from: data)
    }

    public nonisolated func save(_ state: RouteBarState) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writePrivate(encoder.encode(state), to: stateURL, keepBackup: true)
    }

    // MARK: - 设置

    /// 用户是否配置过环境。为假时引擎会去接管机器上已有的 sing-box 服务（见 `LaunchAgentDiscovery`）。
    public nonisolated var hasStoredSettings: Bool {
        FileManager.default.fileExists(atPath: settingsURL.path)
    }

    public nonisolated func loadSettings() throws -> RouteBarSettings {
        guard let data = try readIfPresent(settingsURL) else { return RouteBarSettings.defaults() }
        return try JSONDecoder().decode(RouteBarSettings.self, from: data)
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writePrivate(encoder.encode(settings), to: settingsURL, keepBackup: true)
    }

    // MARK: - 生成副本

    /// 在应用目录留一份生成结果，便于对照排查「装进去的到底是什么」。
    public nonisolated func saveGenerated(_ generated: GeneratedConfiguration) throws {
        try writePrivate(generated.singBoxJSON, to: singBoxURL)
        try writePrivate(Data(generated.surgeProxySection.utf8), to: surgeSnippetURL)
    }

    private nonisolated func readIfPresent(_ url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    /// 私有目录阻止其他用户在原子替换到 chmod 之间访问文件；备份同样含有凭据。
    private nonisolated func writePrivate(_ data: Data, to url: URL, keepBackup: Bool = false) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: rootURL, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path)
        if keepBackup, let previous = try readIfPresent(url), previous != data {
            let backup = url.appendingPathExtension("backup")
            try previous.write(to: backup, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        try data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
