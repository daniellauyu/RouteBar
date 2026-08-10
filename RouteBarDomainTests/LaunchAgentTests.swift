import Foundation
import Testing
@testable import RouteBarDomain

@Suite struct LaunchAgentDefinitionTests {
    private var settings: RouteBarSettings {
        RouteBarSettings(
            singBoxBinaryPath: "/opt/homebrew/bin/sing-box",
            singBoxConfigPath: "/Users/me/.config/sing-box/surge-vless.json",
            singBoxLogPath: "/Users/me/.config/sing-box/out.log",
            singBoxErrorLogPath: "/Users/me/.config/sing-box/err.log",
            surgeProfilePath: "/Users/me/surge.conf",
            launchAgentPath: "/Users/me/Library/LaunchAgents/x.plist",
            launchAgentLabel: "com.example.RouteBar.sing-box")
    }

    @Test func generatesLoadablePlistDerivedFromSettings() throws {
        let data = try LaunchAgentDefinition(settings: settings).propertyListData()
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let plist = try #require(parsed)

        #expect(plist["Label"] as? String == "com.example.RouteBar.sing-box")
        #expect(plist["ProgramArguments"] as? [String] == [
            "/opt/homebrew/bin/sing-box", "run", "-c", "/Users/me/.config/sing-box/surge-vless.json",
        ])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] as? Bool == true)
        #expect(plist["StandardOutPath"] as? String == "/Users/me/.config/sing-box/out.log")
        #expect(plist["StandardErrorPath"] as? String == "/Users/me/.config/sing-box/err.log")
    }

    /// 标记必须存活于「写出→解析」这一轮，否则识别逻辑会把自己写的文件当成别人的。
    @Test func managedMarkerSurvivesSerialization() throws {
        let data = try LaunchAgentDefinition(settings: settings).propertyListData()
        #expect(LaunchAgentDefinition.isManaged(data))
        // 注释在 DOCTYPE 之后，文件仍是合法 plist（上一个测试已经解析成功）。
        #expect(String(decoding: data, as: UTF8.self).contains("<?xml"))
    }

    /// 最关键的一条：用户手写的 plist 绝不能被认成 RouteBar 托管的，
    /// 否则会被静默覆盖，连同其中 RouteBar 不认识的字段一起丢掉。
    @Test func handWrittenPlistIsNotMistakenForManaged() throws {
        let handWritten = try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.example.RouteBar.sing-box",
                               "ProgramArguments": ["/opt/homebrew/bin/sing-box", "run"],
                               "Nice": 5],
            format: .xml, options: 0)
        #expect(!LaunchAgentDefinition.isManaged(handWritten))
    }

    @Test func settingsChangeProducesDifferentPlist() throws {
        var changed = settings
        changed.singBoxBinaryPath = "/usr/local/bin/sing-box"
        let before = try LaunchAgentDefinition(settings: settings).propertyListData()
        let after = try LaunchAgentDefinition(settings: changed).propertyListData()
        #expect(before != after)
    }
}

@Suite struct SettingsDefaultsTests {
    @Test func labelIsDerivedFromBundleIdentifierRatherThanHardcodedAuthor() {
        let settings = RouteBarSettings.defaults(
            home: URL(fileURLWithPath: "/Users/me"),
            bundleIdentifier: "com.example.RouteBar",
            executableExists: { _ in true })
        #expect(settings.launchAgentLabel == "com.example.RouteBar.sing-box")
        #expect(!settings.launchAgentLabel.contains("daniellau"))
    }

    @Test func singBoxPathProbesKnownPrefixes() {
        // Intel Mac：Apple Silicon 前缀不存在时应落到 /usr/local。
        let intel = RouteBarSettings.defaults(
            home: URL(fileURLWithPath: "/Users/me"),
            bundleIdentifier: "com.example.RouteBar",
            executableExists: { $0 == "/usr/local/bin/sing-box" })
        #expect(intel.singBoxBinaryPath == "/usr/local/bin/sing-box")

        // 一个都探不到时给出 Apple Silicon 路径，而不是空串。
        let none = RouteBarSettings.defaults(
            home: URL(fileURLWithPath: "/Users/me"),
            bundleIdentifier: "com.example.RouteBar",
            executableExists: { _ in false })
        #expect(none.singBoxBinaryPath == "/opt/homebrew/bin/sing-box")
    }

    /// 没装 Surge 的机器不能默认「写入 Surge 配置」。
    ///
    /// 以前无条件默认 `.profile`，结果没装 Surge 的人一导入订阅就撞上「Surge 托管配置
    /// 不存在」——而他根本不需要那份配置，他要的是节点页上那批端口。默认值必须在这台
    /// 机器上真的走得通，否则新用户第一次用就卡死在一个与他无关的依赖上。
    @Test func outputModeDefaultsAwayFromSurgeWhenSurgeIsNotInstalled() {
        let profilesDirectory = "/Users/me/Library/Application Support/Surge/Profiles"

        let withSurge = RouteBarSettings.defaults(
            home: URL(fileURLWithPath: "/Users/me"),
            bundleIdentifier: "com.example.RouteBar",
            executableExists: { _ in true },
            directoryExists: { $0 == profilesDirectory })
        #expect(withSurge.outputMode == .profile)

        let withoutSurge = RouteBarSettings.defaults(
            home: URL(fileURLWithPath: "/Users/me"),
            bundleIdentifier: "com.example.RouteBar",
            executableExists: { _ in true },
            directoryExists: { _ in false })
        // 订阅地址那种方式不需要任何预先存在的文件，是唯一开箱就走得通的默认值。
        #expect(withoutSurge.outputMode == .subscription)
        #expect(!withoutSurge.outputMode.writesProfile)
    }
}

@Suite struct LaunchAgentDiscoveryTests {
    private func plist(_ contents: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0)
    }

    /// 接管既有服务时，判定只看启动命令——Label 和文件名是任人取的，做不了依据。
    @Test func adoptsExistingSingBoxAgentRegardlessOfItsLabel() throws {
        let unrelated = try plist(["Label": "com.someone.backup",
                                   "ProgramArguments": ["/usr/bin/rsync", "-a", "/x", "/y"]])
        let singBox = try plist([
            "Label": "com.daniellau.sing-box-surge",
            "ProgramArguments": ["/opt/homebrew/bin/sing-box", "run", "-c",
                                 "/Users/me/.config/sing-box/surge-vless.json"],
            "StandardOutPath": "/Users/me/.config/sing-box/out.log",
            "StandardErrorPath": "/Users/me/.config/sing-box/err.log",
        ])

        let found = try #require(LaunchAgentDiscovery.discover(plists: [
            ("/Users/me/Library/LaunchAgents/backup.plist", unrelated),
            ("/Users/me/Library/LaunchAgents/singbox.plist", singBox),
        ]))

        #expect(found.label == "com.daniellau.sing-box-surge")
        #expect(found.configPath == "/Users/me/.config/sing-box/surge-vless.json")

        let settings = LaunchAgentDiscovery.adopt(found, into: RouteBarSettings.defaults(
            home: URL(fileURLWithPath: "/Users/me"),
            bundleIdentifier: "com.example.RouteBar",
            executableExists: { _ in true }))
        #expect(settings.launchAgentLabel == "com.daniellau.sing-box-surge")
        #expect(settings.launchAgentPath == "/Users/me/Library/LaunchAgents/singbox.plist")
        #expect(settings.singBoxLogPath == "/Users/me/.config/sing-box/out.log")
        // plist 里没有 Surge 配置这一项，应保留默认值而不是被清空。
        #expect(settings.surgeProfilePath.hasSuffix("Surge/Profiles/surge-singbox.conf"))
    }

    @Test func ignoresAgentsThatAreNotSingBox() throws {
        let other = try plist(["Label": "com.other.thing",
                               "ProgramArguments": ["/usr/local/bin/mihomo", "-d", "/x"]])
        #expect(LaunchAgentDiscovery.discover(plists: [("/x.plist", other)]) == nil)
    }

    /// 没有 `-c <配置>` 的 sing-box 服务无法推断配置路径，宁可不认也不要猜。
    @Test func ignoresSingBoxAgentWithoutConfigArgument() throws {
        let incomplete = try plist(["Label": "com.x.sing-box",
                                    "ProgramArguments": ["/opt/homebrew/bin/sing-box", "run"]])
        #expect(LaunchAgentDiscovery.discover(plists: [("/x.plist", incomplete)]) == nil)
    }
}
