import Foundation
import Testing
@testable import RouteBarDomain

@Suite struct SurgeOutputTests {
    private func node(_ id: String) -> ProxyNode {
        ProxyNode(id: id, name: "节点\(id)", server: "\(id).example.com", serverPort: 443,
                  uuid: "11111111-1111-1111-1111-111111111111", flow: "xtls-rprx-vision",
                  serverName: "www.apple.com", publicKey: "pk", shortID: "sid",
                  fingerprint: "chrome", sourceIDs: [UUID()], isEnabled: true)
    }

    /// policy-path 拿到的必须是裸策略行。带上 [Proxy] 段头 Surge 解析不了——
    /// 这一点是照着 sub.store 实际返回的内容确认的。
    @Test func policyListHasNoSectionHeader() throws {
        let generated = try ConfigurationGenerator.generate(nodes: [node("a"), node("b")])
        let list = generated.surgePolicyList

        #expect(!list.contains("[Proxy]"))
        let lines = list.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.contains(" = socks5, 127.0.0.1, ") })
        // 与写进配置文件的那份是同一批代理，只是少了段头。
        #expect(generated.surgeProxySection.contains("[Proxy]"))
        for line in lines { #expect(generated.surgeProxySection.contains(line)) }
    }

    @Test func outputModeControlsWhichSideIsWritten() {
        #expect(SurgeOutputMode.profile.writesProfile)
        #expect(!SurgeOutputMode.profile.servesSubscription)
        #expect(!SurgeOutputMode.subscription.writesProfile)
        #expect(SurgeOutputMode.subscription.servesSubscription)
        #expect(SurgeOutputMode.both.writesProfile && SurgeOutputMode.both.servesSubscription)
    }

    /// 新增字段不能让旧 settings.json 解不出来：`loadSettings` 解码失败会静默回落到
    /// 默认值，那样升级一次就把用户配好的路径（含接管到的 Label）冲掉了。
    @Test func oldSettingsFileStillDecodes() throws {
        let legacy = """
        {"launchAgentLabel":"com.daniellau.sing-box-surge",
         "launchAgentPath":"/Users/me/Library/LaunchAgents/x.plist",
         "singBoxBinaryPath":"/opt/homebrew/bin/sing-box",
         "singBoxConfigPath":"/Users/me/.config/sing-box/c.json",
         "singBoxErrorLogPath":"/Users/me/e.log",
         "singBoxLogPath":"/Users/me/o.log",
         "surgeProfilePath":"/Users/me/s.conf"}
        """
        let decoded = try JSONDecoder().decode(RouteBarSettings.self, from: Data(legacy.utf8))

        #expect(decoded.launchAgentLabel == "com.daniellau.sing-box-surge")
        #expect(decoded.surgeOutputMode == .profile)          // 默认保持原有行为
        #expect(decoded.subscriptionPort == 7899)
        #expect(decoded.subscriptionToken.count == 16)        // 缺失时自动补一个
    }

    @Test func subscriptionURLIsLoopbackOnlyAndCarriesToken() {
        var settings = RouteBarSettings.defaults(
            home: URL(fileURLWithPath: "/Users/me"),
            bundleIdentifier: "com.example.RouteBar",
            executableExists: { _ in true })
        settings.subscriptionPort = 7899
        settings.subscriptionToken = "abcdef0123456789"
        #expect(settings.subscriptionURL == "http://127.0.0.1:7899/abcdef0123456789/proxies")
    }
}
