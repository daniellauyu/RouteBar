import Foundation

/// 用户可配置的环境路径。
///
/// RouteBar 不自带 sing-box，也不接管 Surge 的安装位置——它把两者接起来。
/// 因此所有外部路径都是设置项而不是硬编码常量：Homebrew 前缀、Surge 配置名、
/// LaunchAgent Label 在不同机器上都不一样。
public struct RouteBarSettings: nonisolated Codable, nonisolated Equatable, Sendable {
    public var singBoxBinaryPath: String
    public var singBoxConfigPath: String
    public var singBoxLogPath: String
    public var singBoxErrorLogPath: String
    public var surgeProfilePath: String
    public var launchAgentPath: String
    public var launchAgentLabel: String
    /// 节点交给 Surge 的方式，见 `SurgeOutputMode`。
    public var surgeOutputMode: SurgeOutputMode
    /// 本地订阅服务监听的端口。默认避开 sing-box 用的 7701 起的连续段。
    public var subscriptionPort: Int
    /// 订阅地址里的随机路径段。
    ///
    /// 内容本身不含凭据（只有 `socks5, 127.0.0.1, <端口>`），但一个不可猜的路径能挡住
    /// 本机其它程序顺手扫端口扫出来，代价只有几行。首次需要时生成并存下来，保持地址稳定。
    public var subscriptionToken: String
    /// 输出给 Surge 的节点名模板，占位符见 `NodeNaming`。
    /// 每条订阅可以用 `SubscriptionRecord.nodeNameTemplate` 覆盖它。
    public var nodeNameTemplate: String

    public nonisolated init(singBoxBinaryPath: String,
                            singBoxConfigPath: String,
                            singBoxLogPath: String,
                            singBoxErrorLogPath: String,
                            surgeProfilePath: String,
                            launchAgentPath: String,
                            launchAgentLabel: String,
                            surgeOutputMode: SurgeOutputMode = .profile,
                            subscriptionPort: Int = 7899,
                            subscriptionToken: String = RouteBarSettings.makeToken(),
                            nodeNameTemplate: String = NodeNaming.defaultTemplate) {
        self.singBoxBinaryPath = singBoxBinaryPath
        self.singBoxConfigPath = singBoxConfigPath
        self.singBoxLogPath = singBoxLogPath
        self.singBoxErrorLogPath = singBoxErrorLogPath
        self.surgeProfilePath = surgeProfilePath
        self.launchAgentPath = launchAgentPath
        self.launchAgentLabel = launchAgentLabel
        self.surgeOutputMode = surgeOutputMode
        self.subscriptionPort = subscriptionPort
        self.subscriptionToken = subscriptionToken
        self.nodeNameTemplate = nodeNameTemplate
    }

    public nonisolated static func makeToken() -> String {
        (0..<16).map { _ in String(format: "%x", Int.random(in: 0..<16)) }.joined()
    }

    /// 本地订阅地址，直接填进 Surge 策略组的 `policy-path=`。
    public nonisolated var subscriptionURL: String {
        "\(localBaseURL)/proxies"
    }

    /// Web 界面地址。与订阅地址同端口同令牌——两者是同一个信任域，能访问其一就能访问其二。
    public nonisolated var webInterfaceURL: String {
        "\(localBaseURL)/"
    }

    private nonisolated var localBaseURL: String {
        "http://127.0.0.1:\(subscriptionPort)/\(subscriptionToken)"
    }

    // MARK: - 向后兼容的解码
    //
    // 新增字段必须逐个 decodeIfPresent。合成的 Codable 遇到缺失键会整体抛错，而
    // `StateStore.loadSettings` 的写法是「解不出来就回落到默认值」——那样升级一次
    // 就会把用户配好的路径（包括首次启动接管到的 Label）悄悄冲掉。

    private enum CodingKeys: String, CodingKey {
        case singBoxBinaryPath, singBoxConfigPath, singBoxLogPath, singBoxErrorLogPath
        case surgeProfilePath, launchAgentPath, launchAgentLabel
        case surgeOutputMode, subscriptionPort, subscriptionToken, nodeNameTemplate
    }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = RouteBarSettings.defaults()
        singBoxBinaryPath = try container.decode(String.self, forKey: .singBoxBinaryPath)
        singBoxConfigPath = try container.decode(String.self, forKey: .singBoxConfigPath)
        singBoxLogPath = try container.decode(String.self, forKey: .singBoxLogPath)
        singBoxErrorLogPath = try container.decode(String.self, forKey: .singBoxErrorLogPath)
        surgeProfilePath = try container.decode(String.self, forKey: .surgeProfilePath)
        launchAgentPath = try container.decode(String.self, forKey: .launchAgentPath)
        launchAgentLabel = try container.decode(String.self, forKey: .launchAgentLabel)
        surgeOutputMode = try container.decodeIfPresent(SurgeOutputMode.self, forKey: .surgeOutputMode) ?? .profile
        subscriptionPort = try container.decodeIfPresent(Int.self, forKey: .subscriptionPort) ?? fallback.subscriptionPort
        subscriptionToken = try container.decodeIfPresent(String.self, forKey: .subscriptionToken)
            ?? RouteBarSettings.makeToken()
        // 缺失时必须回落到默认模板而不是空串：老版本写下的 settings.json 里没有这个键，
        // 补成空的等于把所有人的节点名换掉，Surge 策略组里存的旧名字会集体失效。
        nodeNameTemplate = try container.decodeIfPresent(String.self, forKey: .nodeNameTemplate)
            ?? NodeNaming.defaultTemplate
    }

    /// Homebrew 在 Apple Silicon 与 Intel 上的前缀不同，装法也可能是别的包管理器。
    /// 按存在性探测，探不到时回落到 Apple Silicon 路径——好过给一个在任何机器上都不对的值。
    public nonisolated static let singBoxSearchPaths = [
        "/opt/homebrew/bin/sing-box",
        "/usr/local/bin/sing-box",
        "/usr/bin/sing-box",
    ]

    /// 默认设置。
    ///
    /// 这些只是**默认值**，7 项全部可以在「环境」页改，改后存进 settings.json。
    /// 已有 settings.json 的机器不受这里变动的影响。
    public nonisolated static func defaults(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        executableExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> RouteBarSettings {
        // Label 从 bundle id 派生：写死成某个作者的名字，别人装上之后
        // 会看到一个与自己无关的服务标识，还得手工改掉才不别扭。
        let label = "\(bundleIdentifier ?? "com.liuyude.RouteBar").sing-box"
        let binary = singBoxSearchPaths.first(where: executableExists) ?? singBoxSearchPaths[0]
        return RouteBarSettings(
            singBoxBinaryPath: binary,
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

    public nonisolated init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
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

    public nonisolated init(paths: RuntimePaths, exists: (URL) -> Bool) {
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
