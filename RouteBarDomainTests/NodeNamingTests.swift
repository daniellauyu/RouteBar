import Foundation
import Testing
@testable import RouteBarDomain

@Suite struct NodeNamingTests {
    private func node(_ name: String, source: UUID? = nil, id: String? = nil) -> ProxyNode {
        ProxyNode(id: id ?? name, name: name, server: "\(name).example.com", serverPort: 443,
                  uuid: "11111111-1111-1111-1111-111111111111", flow: "xtls-rprx-vision",
                  serverName: "www.apple.com", publicKey: "pk", shortID: "sid",
                  fingerprint: "chrome", sourceIDs: source.map { [$0] } ?? [], isEnabled: true)
    }

    private func mapped(_ nodes: [ProxyNode]) -> [PortMappedNode] {
        ConfigurationGenerator.portMapping(nodes: nodes)
    }

    /// 默认模板必须和 1.6.1 写死的名字逐字一致。
    /// 一旦不同，所有人 Surge 策略组里存着的旧名字会集体指向不存在的代理。
    @Test func defaultTemplateReproducesTheHardcodedNames() throws {
        let generated = try ConfigurationGenerator.generate(nodes: [node("Hong Kong 01"), node("Tokyo 02")])

        #expect(generated.policyNames == ["RouteBar 01 - Hong Kong 01", "RouteBar 02 - Tokyo 02"])
        #expect(generated.surgeProxySection.contains("RouteBar 01 - Hong Kong 01 = socks5, 127.0.0.1, 7701"))
    }

    @Test func globalTemplateAppliesToEveryNode() {
        let naming = NodeNaming(template: "🇭🇰 {index}｜{name}｜{port}")
        let names = naming.names(for: mapped([node("Hong Kong 01"), node("Tokyo 02")]))

        #expect(names == ["🇭🇰 01｜Hong Kong 01｜7701", "🇭🇰 02｜Tokyo 02｜7702"])
    }

    /// 逐订阅覆盖：同一批节点按来源分别命名，没设覆盖的那条仍走全局模板。
    @Test func perSubscriptionTemplateOverridesTheGlobalOne() {
        let alpha = SubscriptionRecord(name: "A机场", nodeNameTemplate: "A-{index} {name}")
        let beta = SubscriptionRecord(name: "B机场")
        let naming = NodeNaming(template: "全局 {index}", subscriptions: [alpha, beta])

        // 端口映射按节点名排序，「东京」排在「香港」前面。
        let names = naming.names(for: mapped([node("香港", source: alpha.id), node("东京", source: beta.id)]))

        #expect(names == ["全局 01", "A-02 香港"])
    }

    @Test func subscriptionPlaceholderResolvesToTheSourceName() {
        let record = SubscriptionRecord(name: "A机场")
        let naming = NodeNaming(template: "{subscription} · {name}", subscriptions: [record])

        #expect(naming.names(for: mapped([node("香港", source: record.id)])) == ["A机场 · 香港"])
    }

    /// 节点去重后可能挂着多个来源，命名只能认一个——取订阅列表里靠前的那条，
    /// 否则同一个节点的名字会随 sourceIDs 的排序而变。
    @Test func multiSourceNodeUsesTheFirstSubscriptionInTheList() {
        let first = SubscriptionRecord(name: "先", nodeNameTemplate: "先-{name}")
        let second = SubscriptionRecord(name: "后", nodeNameTemplate: "后-{name}")
        let naming = NodeNaming(template: NodeNaming.defaultTemplate, subscriptions: [first, second])

        var shared = node("香港")
        shared.sourceIDs = [second.id, first.id]

        #expect(naming.names(for: mapped([shared])) == ["先-香港"])
    }

    /// 模板不含序号时同名节点会撞车。Surge 的 [Proxy] 段以名字为键，
    /// 重名的行只有最后一条生效，前面的静默消失——所以必须自动补号。
    @Test func duplicateNamesGetDisambiguated() {
        let naming = NodeNaming(template: "{name}")
        let names = naming.names(for: mapped([node("香港", id: "a"), node("香港", id: "b"), node("香港", id: "c")]))

        #expect(Set(names).count == 3)
        #expect(names[0] == "香港")
    }

    /// 逗号、等号、引号会把 `名字 = socks5, …` 这一行拆坏。模板本身也是用户输入，
    /// 所以清洗放在拼完之后，而不是只洗节点名。
    @Test func syntaxCharactersAreStrippedFromTheWholeRenderedName() {
        let naming = NodeNaming(template: "A=B, {name}")

        #expect(naming.names(for: mapped([node("\"港\", 01")])) == ["A B 港 01"])
    }

    /// 空模板、以及渲染后为空的模板，都不能产出一个空名字：
    /// `= socks5, 127.0.0.1, 7701` 这样的残行会毁掉整段配置。
    @Test func emptyTemplatesFallBackToUsableNames() {
        #expect(NodeNaming(template: "   ").names(for: mapped([node("香港")])) == ["RouteBar 01 - 香港"])
        // {subscription} 是唯一占位符，而节点没有来源时会拼出空串。
        #expect(NodeNaming(template: "{subscription}").names(for: mapped([node("香港")])) == ["RouteBar 01"])
        #expect(NodeNaming.normalized("  ") == NodeNaming.defaultTemplate)
        #expect(NodeNaming.normalized(" {name} ") == "{name}")
    }

    /// 一个节点都没有时也要能预览，否则刚装上还没添加订阅的用户改模板等于盲改。
    @Test func previewFallsBackToSampleNodes() {
        let names = NodeNaming.preview(template: "{index}-{name}", subscriptions: [], mapped: [])

        #expect(names.count == 2)
        #expect(names[0] == "01-香港 01")
    }

    /// 试跑要给出「原名 → 输出名」的对照，而且不能碰任何已保存的设置。
    @Test func previewRowsPairEveryNodeWithItsOutputName() {
        let nodes = mapped([node("香港"), node("东京")])
        let result = NodeNaming.previewRows(template: "机场-{index}", subscriptions: [], mapped: nodes)

        #expect(!result.isSample)
        #expect(result.rows.map(\.originalName) == ["东京", "香港"])
        #expect(result.rows.map(\.outputName) == ["机场-01", "机场-02"])
        #expect(result.rows.map(\.localPort) == [7701, 7702])
    }

    @Test func previewRowsFlagSampleDataWhenNothingIsEnabled() {
        let result = NodeNaming.previewRows(template: "{name}", subscriptions: [], mapped: [])

        #expect(result.isSample)
        #expect(result.rows.map(\.originalName) == ["香港 01", "东京 02"])
    }

    /// 列表逐行要显示输出名，只能按 id 取——顺序在筛选、排序之后就对不上了。
    @Test func namesByNodeIDMatchTheBatchResult() {
        let nodes = mapped([node("香港", id: "hk"), node("东京", id: "tk")])
        let naming = NodeNaming(template: "{index} {name}")

        let byID = naming.namesByNodeID(for: nodes)

        #expect(byID == ["tk": "01 东京", "hk": "02 香港"])
    }

    /// 自定义模板拼出来的名字要真的出现在策略行和 `policyNames` 里。
    ///
    /// 这里原来测的是改写 Surge 配置时策略组那一行怎么拼——那个功能已经去掉了。
    /// 但「名字可配置之后不能再靠 `RouteBar ` 前缀反推」这条约束仍然成立，
    /// 只是现在的落点变成了交给客户端的那份清单。
    @Test func customNamesFlowIntoThePolicyListAndNames() throws {
        let generated = try ConfigurationGenerator.generate(
            nodes: [node("香港"), node("东京")],
            naming: NodeNaming(template: "机场-{index}"))

        #expect(generated.surgePolicyList.contains("机场-01 = socks5, 127.0.0.1, 7701"))
        #expect(generated.policyNames == ["机场-01", "机场-02"])
        #expect(!generated.surgePolicyList.contains("RouteBar"))
    }

    /// 本地订阅服务是按请求现算策略行的，落盘那份是整批生成的。
    /// 两条路径必须用同一份命名规则，否则同一个端口在两处会有两个名字。
    @Test func policyListAndGeneratedOutputShareTheSameNaming() throws {
        let record = SubscriptionRecord(name: "A机场", nodeNameTemplate: "{subscription} {index}")
        let nodes = [node("香港", source: record.id), node("东京", source: record.id)]
        let naming = NodeNaming(template: NodeNaming.defaultTemplate, subscriptions: [record])

        let generated = try ConfigurationGenerator.generate(nodes: nodes, naming: naming)
        let served = ConfigurationGenerator.surgePolicyLines(ConfigurationGenerator.portMapping(nodes: nodes),
                                                             naming: naming)

        #expect(served == generated.surgePolicyList)
        #expect(served.contains("A机场 01 = socks5, 127.0.0.1, 7701"))
    }

    /// 老 state.json 里没有 nodeNameTemplate 这个键。解不出来的话
    /// `RouteBarState` 会整份回落到空状态——升级一次就把用户的订阅全清了。
    @Test func subscriptionsWithoutTheNewKeyStillDecode() throws {
        let legacy = """
        {"subscriptions":[{"id":"11111111-1111-1111-1111-111111111111","name":"A机场","note":"",
          "isEnabled":true,"createdAt":"2025-01-01T00:00:00Z","updateIntervalHours":6,
          "status":"success","nodes":[]}],"autoUpdatePaused":false}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let state = try decoder.decode(RouteBarState.self, from: Data(legacy.utf8))

        #expect(state.subscriptions.count == 1)
        #expect(state.subscriptions[0].nodeNameTemplate == nil)
    }

    /// 同理，老 settings.json 里没有全局模板，必须补成默认值而不是空串。
    @Test func settingsWithoutTheNewKeyKeepTheLegacyTemplate() throws {
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

        #expect(decoded.nodeNameTemplate == NodeNaming.defaultTemplate)
    }
}
