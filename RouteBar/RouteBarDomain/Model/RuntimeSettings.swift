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
    public var launchAgentPath: String
    public var launchAgentLabel: String
    /// 本地订阅服务监听的端口。默认避开 sing-box 用的 7701 起的连续段。
    public var subscriptionPort: Int
    /// 订阅地址里的随机路径段。
    ///
    /// 内容本身不含凭据（只有 `socks5, 127.0.0.1, <端口>`），但一个不可猜的路径能挡住
    /// 本机其它程序顺手扫端口扫出来，代价只有几行。首次需要时生成并存下来，保持地址稳定。
    public var subscriptionToken: String
    /// 生成的节点名模板，占位符见 `NodeNaming`。两种 Surge 接法用的都是它。
    /// 每条订阅可以用 `SubscriptionRecord.nodeNameTemplate` 覆盖它。
    /// 只在 `nodeNamingStyle == .template` 时生效。
    public var nodeNameTemplate: String
    /// 节点名怎么生成：套模板，还是压成 `【来源】地区NN` 的规范化形式。
    ///
    /// 默认是模板——这个键是后加的，老 settings.json 里没有，回落成规范化
    /// 会把所有人 Surge 策略组里存着的名字一次性换掉。
    public var nodeNamingStyle: NodeNamingStyle
    /// 规范化用的地区识别表，顺序即优先级。只在 `nodeNamingStyle == .normalized` 时生效。
    public var regionRules: [RegionRule]
    /// 逐连接记录目标域名与出口节点。默认关闭，警告和错误始终记录。
    public var connectionLoggingEnabled: Bool

    public nonisolated init(singBoxBinaryPath: String,
                            singBoxConfigPath: String,
                            singBoxLogPath: String,
                            singBoxErrorLogPath: String,
                            launchAgentPath: String,
                            launchAgentLabel: String,
                            subscriptionPort: Int = 7899,
                            subscriptionToken: String = RouteBarSettings.makeToken(),
                            nodeNameTemplate: String = NodeNaming.defaultTemplate,
                            nodeNamingStyle: NodeNamingStyle = .template,
                            regionRules: [RegionRule] = NodeNormalization.defaultRegionRules,
                            connectionLoggingEnabled: Bool = false) {
        self.singBoxBinaryPath = singBoxBinaryPath
        self.singBoxConfigPath = singBoxConfigPath
        self.singBoxLogPath = singBoxLogPath
        self.singBoxErrorLogPath = singBoxErrorLogPath
        self.launchAgentPath = launchAgentPath
        self.launchAgentLabel = launchAgentLabel
        self.subscriptionPort = subscriptionPort
        self.subscriptionToken = subscriptionToken
        self.nodeNameTemplate = nodeNameTemplate
        self.nodeNamingStyle = nodeNamingStyle
        self.regionRules = regionRules
        self.connectionLoggingEnabled = connectionLoggingEnabled
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

    /// 可以直接粘进 Surge `[Proxy Group]` 段的那一行，省得用户自己拼。
    ///
    /// 窗口、网页、命令行都要给出这一行，各拼一遍的话，改个参数就会有一处忘记跟上，
    /// 而用户照着抄的偏偏可能是没跟上的那一处。
    public nonisolated var surgePolicyGroupLine: String {
        "🔰 RouteBar = select, policy-path=\(subscriptionURL), update-interval=0"
    }

    private nonisolated var localBaseURL: String {
        "http://127.0.0.1:\(subscriptionPort)/\(subscriptionToken)"
    }

    // MARK: - 向后兼容的解码
    //
    // 新增字段必须逐个 decodeIfPresent。合成的 Codable 遇到缺失键会整体抛错，而
    // `StateStore.loadSettings` 的写法是「解不出来就回落到默认值」——那样升级一次
    // 就会把用户配好的路径（包括首次启动接管到的 Label）悄悄冲掉。

    // 老 settings.json 里还留着 `surgeProfilePath` 与 `surgeOutputMode` 两个键。
    // 不在这里声明，解码时会被直接忽略；下一次保存就从文件里消失。
    // 无须迁移代码——它们承载的功能已经整个去掉了，没有任何东西需要从中恢复。
    private enum CodingKeys: String, CodingKey {
        case singBoxBinaryPath, singBoxConfigPath, singBoxLogPath, singBoxErrorLogPath
        case launchAgentPath, launchAgentLabel
        case subscriptionPort, subscriptionToken, nodeNameTemplate
        case nodeNamingStyle, regionRules, connectionLoggingEnabled
    }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = RouteBarSettings.defaults()
        singBoxBinaryPath = try container.decode(String.self, forKey: .singBoxBinaryPath)
        singBoxConfigPath = try container.decode(String.self, forKey: .singBoxConfigPath)
        singBoxLogPath = try container.decode(String.self, forKey: .singBoxLogPath)
        singBoxErrorLogPath = try container.decode(String.self, forKey: .singBoxErrorLogPath)
        launchAgentPath = try container.decode(String.self, forKey: .launchAgentPath)
        launchAgentLabel = try container.decode(String.self, forKey: .launchAgentLabel)
        subscriptionPort = try container.decodeIfPresent(Int.self, forKey: .subscriptionPort) ?? fallback.subscriptionPort
        subscriptionToken = try container.decodeIfPresent(String.self, forKey: .subscriptionToken)
            ?? RouteBarSettings.makeToken()
        // 缺失时必须回落到默认模板而不是空串：老版本写下的 settings.json 里没有这个键，
        // 补成空的等于把所有人的节点名换掉，Surge 策略组里存的旧名字会集体失效。
        nodeNameTemplate = try container.decodeIfPresent(String.self, forKey: .nodeNameTemplate)
            ?? NodeNaming.defaultTemplate
        // 同理：缺这个键的是升级上来的老配置，必须当作模板模式，否则一次升级
        // 就把名字从 `RouteBar 01 - 香港` 换成 `【机场】香港01`，策略组集体失效。
        nodeNamingStyle = try container.decodeIfPresent(NodeNamingStyle.self, forKey: .nodeNamingStyle)
            ?? .template
        // 地区表存的是用户改过的那一份，为空（键缺失或被清空）时用内置表——
        // 空表会让每个节点都认不出地区、全部堆进「小众」。
        let decodedRules = try container.decodeIfPresent([RegionRule].self, forKey: .regionRules) ?? []
        regionRules = decodedRules.isEmpty ? NodeNormalization.defaultRegionRules : decodedRules
        connectionLoggingEnabled = try container.decodeIfPresent(Bool.self, forKey: .connectionLoggingEnabled) ?? false
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
    /// 这些只是**默认值**，全部可以在「环境」页改，改后存进 settings.json。
    /// 已有 settings.json 的机器不受这里变动的影响。
    ///
    /// 现在每一项都指向 RouteBar 自己创建的东西，所以默认值总是对的。曾经有一项不是：
    /// Surge 托管配置的路径只能猜一个文件名（`surge-singbox.conf`），而 Surge 的配置
    /// 由用户自己命名，猜中的概率接近零——那正是「导入节点失败」的来源。
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
    public nonisolated var launchAgent: URL { URL(fileURLWithPath: settings.launchAgentPath) }
    public nonisolated var appSupportDirectory: URL {
        home.appendingPathComponent("Library/Application Support/RouteBar", isDirectory: true)
    }
    public nonisolated var singBoxConfigDirectory: URL { singBoxConfig.deletingLastPathComponent() }
    /// launchctl 的服务标识：用户态 GUI 域 + Label。
    public nonisolated var launchctlTarget: String { "gui/\(userID)/\(settings.launchAgentLabel)" }
}

public enum EnvironmentItemState: String, Codable, Sendable {
    case ready
    case missing
}

/// 环境自检结果：RouteBar 依赖的外部落点是否就位。
///
/// 这三项就是全部依赖，而且每一项都是 RouteBar 自己要读写的东西。曾经还有两项
/// 「Surge Profiles 目录」和「Surge 托管配置」——那是改写 Surge 配置那种输出方式
/// 留下的，它依赖一份**由别的应用创建、名字由用户自己起**的文件。默认值只能靠猜，
/// 猜错就报「配置不存在」，而绝大多数人根本不需要那个文件。功能去掉后这两项一并消失。
public struct RouteBarEnvironmentReport: Equatable, Sendable {
    public let singBoxBinary: EnvironmentItemState
    public let singBoxConfigDirectory: EnvironmentItemState
    public let launchAgent: EnvironmentItemState

    public nonisolated init(paths: RuntimePaths, exists: (URL) -> Bool) {
        singBoxBinary = exists(paths.singBoxBinary) ? .ready : .missing
        singBoxConfigDirectory = exists(paths.singBoxConfigDirectory) ? .ready : .missing
        launchAgent = exists(paths.launchAgent) ? .ready : .missing
    }

    public nonisolated var needsSetup: Bool { missingCount > 0 }

    public nonisolated var missingCount: Int {
        [singBoxBinary, singBoxConfigDirectory, launchAgent].filter { $0 == .missing }.count
    }
}
