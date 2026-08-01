import Foundation

/// 用户可配置的环境路径。
///
/// RouteBar 不自带 sing-box，也不接管 Surge 的安装位置——它把两者接起来。
/// 因此所有外部路径都是设置项而不是硬编码常量：Homebrew 前缀、Surge 配置名、
/// LaunchAgent Label 在不同机器上都不一样。
public struct RouteBarSettings: Codable, Equatable, Sendable {
    public var singBoxBinaryPath: String
    public var singBoxConfigPath: String
    public var singBoxLogPath: String
    public var singBoxErrorLogPath: String
    public var surgeProfilePath: String
    public var launchAgentPath: String
    public var launchAgentLabel: String

    public init(singBoxBinaryPath: String,
                singBoxConfigPath: String,
                singBoxLogPath: String,
                singBoxErrorLogPath: String,
                surgeProfilePath: String,
                launchAgentPath: String,
                launchAgentLabel: String) {
        self.singBoxBinaryPath = singBoxBinaryPath
        self.singBoxConfigPath = singBoxConfigPath
        self.singBoxLogPath = singBoxLogPath
        self.singBoxErrorLogPath = singBoxErrorLogPath
        self.surgeProfilePath = surgeProfilePath
        self.launchAgentPath = launchAgentPath
        self.launchAgentLabel = launchAgentLabel
    }

    public nonisolated static func defaults(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> RouteBarSettings {
        let label = "com.daniellau.sing-box-surge"
        return RouteBarSettings(
            singBoxBinaryPath: "/opt/homebrew/bin/sing-box",
            singBoxConfigPath: home.appendingPathComponent(".config/sing-box/surge-vless.json").path,
            singBoxLogPath: home.appendingPathComponent(".config/sing-box/surge-vless.log").path,
            singBoxErrorLogPath: home.appendingPathComponent(".config/sing-box/surge-vless-error.log").path,
            surgeProfilePath: home.appendingPathComponent("Library/Application Support/Surge/Profiles/surge-singbox.conf").path,
            launchAgentPath: home.appendingPathComponent("Library/LaunchAgents/\(label).plist").path,
            launchAgentLabel: label
        )
    }
}

/// 由设置推导出的具体路径与 launchctl 目标。
public struct RuntimePaths: Sendable, Equatable {
    public let home: URL
    public let userID: uid_t
    public let settings: RouteBarSettings

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                userID: uid_t = getuid(),
                settings: RouteBarSettings? = nil) {
        self.home = home
        self.userID = userID
        self.settings = settings ?? RouteBarSettings.defaults(home: home)
    }

    public nonisolated var label: String { settings.launchAgentLabel }
    public nonisolated var singBoxBinary: URL { URL(fileURLWithPath: settings.singBoxBinaryPath) }
    public nonisolated var singBoxConfig: URL { URL(fileURLWithPath: settings.singBoxConfigPath) }
    public nonisolated var singBoxLog: URL { URL(fileURLWithPath: settings.singBoxLogPath) }
    public nonisolated var singBoxErrorLog: URL { URL(fileURLWithPath: settings.singBoxErrorLogPath) }
    public nonisolated var surgeProfile: URL { URL(fileURLWithPath: settings.surgeProfilePath) }
    public nonisolated var launchAgent: URL { URL(fileURLWithPath: settings.launchAgentPath) }
    public nonisolated var appSupportDirectory: URL {
        home.appendingPathComponent("Library/Application Support/RouteBar", isDirectory: true)
    }
    public nonisolated var surgeProfilesDirectory: URL {
        home.appendingPathComponent("Library/Application Support/Surge/Profiles", isDirectory: true)
    }
    public nonisolated var singBoxConfigDirectory: URL { singBoxConfig.deletingLastPathComponent() }
    /// launchctl 的服务标识：用户态 GUI 域 + Label。
    public nonisolated var launchctlTarget: String { "gui/\(userID)/\(settings.launchAgentLabel)" }
}

public enum EnvironmentItemState: String, Codable, Sendable {
    case ready
    case missing
}

/// 环境自检结果：RouteBar 依赖的五个外部落点是否就位。
public struct RouteBarEnvironmentReport: Equatable, Sendable {
    public let singBoxBinary: EnvironmentItemState
    public let surgeProfilesDirectory: EnvironmentItemState
    public let surgeProfile: EnvironmentItemState
    public let singBoxConfigDirectory: EnvironmentItemState
    public let launchAgent: EnvironmentItemState

    public init(paths: RuntimePaths, exists: (URL) -> Bool) {
        singBoxBinary = exists(paths.singBoxBinary) ? .ready : .missing
        surgeProfilesDirectory = exists(paths.surgeProfilesDirectory) ? .ready : .missing
        surgeProfile = exists(paths.surgeProfile) ? .ready : .missing
        singBoxConfigDirectory = exists(paths.singBoxConfigDirectory) ? .ready : .missing
        launchAgent = exists(paths.launchAgent) ? .ready : .missing
    }

    public nonisolated var needsSetup: Bool { missingCount > 0 }

    public nonisolated var missingCount: Int {
        [singBoxBinary, surgeProfilesDirectory, surgeProfile, singBoxConfigDirectory, launchAgent]
            .filter { $0 == .missing }.count
    }
}
