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

    /// 每一行都必须带 `udp-relay=true`。
    ///
    /// Surge 对 SOCKS5 代理默认不转发 UDP。漏掉这一项时 TCP 一切正常，只有 QUIC、游戏、
    /// 部分视频流悄悄退化——没有任何报错，日志里也看不出来，所以只能在这里钉死。
    @Test func everyPolicyLineEnablesUDPRelay() throws {
        let generated = try ConfigurationGenerator.generate(nodes: [node("a"), node("b")])

        let lines = generated.surgePolicyList.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.hasSuffix(", udp-relay=true") })
        #expect(generated.surgeProxySection
            .contains("节点a = socks5, 127.0.0.1, 7701, udp-relay=true"))
    }

    /// 订阅地址返回的列表和写进配置文件的 `[Proxy]` 段必须逐字节同源。
    ///
    /// 两边各拼一遍的话，网页上看到的名字和落盘那份对不上，
    /// 而这种错位只有逐行比对才看得出来。
    @Test func policyLinesAreTheSingleSourceForBothOutputs() throws {
        let nodes = [node("a"), node("b"), node("c")]
        let generated = try ConfigurationGenerator.generate(nodes: nodes)
        let standalone = ConfigurationGenerator.surgePolicyLines(generated.nodes)

        #expect(standalone == generated.surgePolicyList)
        #expect(generated.surgeProxySection == "[Proxy]\n" + standalone)
    }

    /// 本地服务是按请求现算策略行的，用的是快照里的端口映射。
    /// 那份映射必须和真正写进 sing-box 的编号一致，否则 Surge 会连到不存在的端口。
    @Test func policyLinesFromPortMappingMatchFullGeneration() throws {
        let nodes = [node("a"), node("b"), node("c")]
        let fromMapping = ConfigurationGenerator.surgePolicyLines(
            ConfigurationGenerator.portMapping(nodes: nodes))

        #expect(fromMapping == (try ConfigurationGenerator.generate(nodes: nodes)).surgePolicyList)
    }

    /// 协议标签区分带不带 Reality。四个界面（窗口列表、详情栏、网页、命令行）读同一处，
    /// 详情栏原来写死的 "VLESS over TCP" 已换掉——写死的话它永远不会跟着解析器变。
    @Test func protocolLabelDistinguishesRealityFromPlainVLESS() {
        #expect(node("a").protocolLabel == "VLESS-Reality")

        var plain = node("b")
        plain.publicKey = ""
        #expect(plain.protocolLabel == "VLESS")
    }

    /// 字段增删都不能让旧 settings.json 解不出来。
    ///
    /// `loadSettings` 解码失败会静默回落到默认值，那样升级一次就把用户配好的路径
    /// （含首次启动接管到的 Label）冲掉了。这份夹具特意保留了两个**已经删掉**的键
    /// `surgeProfilePath` 与 `surgeOutputMode`——盘上每一台老机器都还有它们，
    /// 多出来的键必须被安静忽略，而不是让整份设置解码失败。
    @Test func oldSettingsFileStillDecodes() throws {
        let legacy = """
        {"launchAgentLabel":"com.daniellau.sing-box-surge",
         "launchAgentPath":"/Users/me/Library/LaunchAgents/x.plist",
         "singBoxBinaryPath":"/opt/homebrew/bin/sing-box",
         "singBoxConfigPath":"/Users/me/.config/sing-box/c.json",
         "singBoxErrorLogPath":"/Users/me/e.log",
         "singBoxLogPath":"/Users/me/o.log",
         "surgeOutputMode":"profile",
         "surgeProfilePath":"/Users/me/s.conf"}
        """
        let decoded = try JSONDecoder().decode(RouteBarSettings.self, from: Data(legacy.utf8))

        #expect(decoded.launchAgentLabel == "com.daniellau.sing-box-surge")
        #expect(decoded.subscriptionPort == 7899)
        #expect(decoded.subscriptionToken.count == 16)        // 缺失时自动补一个

        // 写回去时那两个键不该再出现——功能没了，留着只会让人以为还能配。
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        #expect(object["surgeOutputMode"] == nil)
        #expect(object["surgeProfilePath"] == nil)
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
