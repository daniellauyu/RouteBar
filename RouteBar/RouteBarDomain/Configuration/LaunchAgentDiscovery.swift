import Foundation

/// 在机器上发现的、已经在跑 sing-box 的 LaunchAgent。
public struct DiscoveredLaunchAgent: Sendable, Equatable {
    public let label: String
    public let plistPath: String
    public let binaryPath: String
    public let configPath: String
    public let standardOutPath: String?
    public let standardErrorPath: String?

    public nonisolated init(label: String, plistPath: String, binaryPath: String, configPath: String,
                            standardOutPath: String?, standardErrorPath: String?) {
        self.label = label
        self.plistPath = plistPath
        self.binaryPath = binaryPath
        self.configPath = configPath
        self.standardOutPath = standardOutPath
        self.standardErrorPath = standardErrorPath
    }
}

/// 首次启动时接管已有的 sing-box 服务。
///
/// 会用 RouteBar 的人，多半已经自己手搭了一套 sing-box + LaunchAgent。如果不认这份既有配置，
/// 应用起来就会显示「LaunchAgent 未找到、服务已停止」——而用户的代理明明跑得好好的，
/// 只是标识对不上。他还得手工把 Label 和四个路径抄进设置里才能对上号。
///
/// 只在**没有 settings.json**（即从没配置过）时执行，绝不覆盖用户已保存的选择。
public enum LaunchAgentDiscovery {
    /// 从一批 plist 内容里挑出运行 sing-box 的那个。
    ///
    /// 判定依据是 `ProgramArguments`：第一项以 `sing-box` 结尾，且带 `run -c <配置>`。
    /// 不看 Label 或文件名——那些是任人取的，只有真正的启动命令做不了假。
    public nonisolated static func discover(plists: [(path: String, data: Data)]) -> DiscoveredLaunchAgent? {
        for plist in plists {
            guard let parsed = try? PropertyListSerialization.propertyList(from: plist.data, format: nil),
                  let contents = parsed as? [String: Any],
                  let label = contents["Label"] as? String,
                  let arguments = contents["ProgramArguments"] as? [String],
                  let binary = arguments.first,
                  URL(fileURLWithPath: binary).lastPathComponent.hasPrefix("sing-box"),
                  let configIndex = arguments.firstIndex(of: "-c"),
                  arguments.indices.contains(configIndex + 1) else { continue }

            return DiscoveredLaunchAgent(
                label: label,
                plistPath: plist.path,
                binaryPath: binary,
                configPath: arguments[configIndex + 1],
                standardOutPath: contents["StandardOutPath"] as? String,
                standardErrorPath: contents["StandardErrorPath"] as? String
            )
        }
        return nil
    }

    /// 把发现结果并进默认设置。
    ///
    /// 只覆盖 plist 里确实写了的字段；Surge 配置路径 plist 里没有，保留默认值。
    public nonisolated static func adopt(_ discovered: DiscoveredLaunchAgent,
                                         into base: RouteBarSettings) -> RouteBarSettings {
        var settings = base
        settings.launchAgentLabel = discovered.label
        settings.launchAgentPath = discovered.plistPath
        settings.singBoxBinaryPath = discovered.binaryPath
        settings.singBoxConfigPath = discovered.configPath
        if let out = discovered.standardOutPath { settings.singBoxLogPath = out }
        if let error = discovered.standardErrorPath { settings.singBoxErrorLogPath = error }
        return settings
    }
}
