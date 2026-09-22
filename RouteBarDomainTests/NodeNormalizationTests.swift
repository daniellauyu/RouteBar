import Foundation
import Testing
@testable import RouteBarDomain

/// 规范化命名的规则表。
///
/// 这里的节点名全部照抄真实订阅——地区认错、信息节点漏判在 Surge 那边不会报错，
/// 只表现为「某个组里少了几个节点」或者「url-test 组里多了几条永远失败的项」，
/// 靠肉眼是发现不了的，只能用例子钉住。
@Suite("规范化命名") struct NodeNormalizationTests {
    private let rules = NodeNormalization.defaultRegionRules

    private func region(_ name: String) -> String {
        NodeNormalization.region(of: name, rules: rules)
    }

    // MARK: - 地区识别

    @Test("认得出机场那些花名里的地区") func recognizesRegionsInNoisyNames() {
        #expect(region("[vip1] ⑮香港︱Vless ｜×1倍率｜限速100M") == "香港")
        #expect(region("[vip1]⑱美国︱Hysteria2｜×1倍率｜限速100M") == "美国")
        #expect(region("[vip1]㉑日本︱Vless｜×1倍率｜限速100M") == "日本")
        #expect(region("L+ 德國1 VT") == "德国")
        #expect(region("L+ 韓國 KR-VT") == "韩国")
        #expect(region("L+ 俄羅斯 RS-VT") == "俄罗斯")
    }

    /// 「台灣」既不是「台湾」也不是「臺灣」——简繁混写，两个字各来自一边。
    /// Surge 配置里那条 `(台湾)|(臺灣)|(Taiwan)|(Tai)|(TW)` 正是漏在这里，
    /// 七个 STOTIK 台湾节点一个都没进台湾组。
    @Test("台湾的四种写法都归到同一个地区") func taiwanVariantsCollapse() {
        #expect(region("L+ 台灣 Ax-VT") == "台湾")
        #expect(region("L+ 台灣 CN2 VT") == "台湾")
        #expect(region("臺灣 01") == "台湾")
        #expect(region("台湾 01") == "台湾")
        #expect(region("Taiwan 01") == "台湾")
    }

    /// 两个字母的代码必须按单词边界匹配。`includes("US")` 会让 `RUSSIA` 变成美国，
    /// 而俄罗斯节点混进美国组这种事，只有挨个点开测延迟才看得出来。
    @Test("短代码不会被长单词吃掉") func shortCodesRequireWordBoundaries() {
        #expect(region("RUSSIA-01") == "俄罗斯")
        #expect(region("US-01") == "美国")
        #expect(region("美国US节点") == "美国")
        // ID 是印尼，但 MADRID 里的 ID 不算。
        #expect(region("MADRID-01") == "小众")
        #expect(region("ID-01") == "印尼")
    }

    @Test("认不出来的落到小众") func unknownFallsBackToNiche() {
        #expect(region("喀麦隆 01") == "小众")
        #expect(region("") == "小众")
    }

    // MARK: - 订阅信息节点

    @Test("认得出四类订阅信息") func classifiesInfoEntries() {
        #expect(NodeNormalization.infoKind(of: "更新時間：2026-09-22 14:29") == .update)
        #expect(NodeNormalization.infoKind(of: "剩余流量：89.98 GB") == .traffic)
        #expect(NodeNormalization.infoKind(of: "到期時間：2027-03-30 23:42") == .expire)
        #expect(NodeNormalization.infoKind(of: "套餐到期：2027-02-05") == .expire)
        #expect(NodeNormalization.infoKind(of: "[vip1] ⑮香港︱Vless") == nil)
    }

    /// 「距离下次重置剩余：13 天」以前没人认领：三个 isXxxInfo 都不匹配，于是被当成
    /// 普通节点、认不出地区、变成「小众01」，堆在小众节点组里当一条连不通的死项。
    @Test("重置日不再漏进普通节点") func resetDayIsAnInfoEntry() {
        #expect(NodeNormalization.infoKind(of: "距离下次重置剩余：13 天") == .reset)
    }

    @Test("信息节点取值") func extractsInfoValues() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let zone = TimeZone(identifier: "Asia/Shanghai")!

        #expect(NodeNormalization.infoValue(of: "剩余流量：89.98 GB", kind: .traffic,
                                            now: now, timeZone: zone) == "89.98 GB")
        #expect(NodeNormalization.infoValue(of: "距离下次重置剩余：13 天", kind: .reset,
                                            now: now, timeZone: zone) == "13 天")
        // 到期只保留日期，机场那个时分秒没用。
        #expect(NodeNormalization.infoValue(of: "到期時間：2027-03-30 23:42", kind: .expire,
                                            now: now, timeZone: zone) == "2027-03-30")
        #expect(NodeNormalization.infoValue(of: "套餐到期：2027-2-5", kind: .expire,
                                            now: now, timeZone: zone) == "2027-02-05")
    }

    @Test("续约线路不输出") func renewalEntriesAreDropped() {
        #expect(NodeNormalization.isRenewalEntry("續約專用線路 - user.stotik.nl"))
        #expect(NodeNormalization.isRenewalEntry("续费专用线路"))
        #expect(!NodeNormalization.isRenewalEntry("[vip1] ⑮香港︱Vless"))
    }

    // MARK: - 整批规划

    private func input(_ name: String, _ source: String, rank: Int = 0,
                       updatedAt: Date? = nil) -> NormalizationInput {
        NormalizationInput(name: name, sourceName: source, sourceRank: rank, sourceUpdatedAt: updatedAt)
    }

    @Test("按来源与地区分别编号") func numbersPerSourceAndRegion() {
        let plan = NodeNormalization.plan([
            input("[vip1] ⑮香港︱Vless", "JSSR"),
            input("[vip1]⑪香港 ︱Vless", "JSSR"),
            input("[vip1]⑱美国︱Hysteria2", "JSSR"),
            input("L+ 香港 HK-VT", "STOTIK", rank: 1),
        ], rules: rules)

        #expect(plan.names == ["【JSSR】香港01", "【JSSR】香港02", "【JSSR】美国01", "【STOTIK】香港01"])
        #expect(plan.lines.map(\.index) == [0, 1, 2, 3])
        // 没有信息节点就不该凭空多出一条入口。
        #expect(plan.lines.count == 4)
    }

    @Test("信息节点排到最后，按订阅顺序再按类型") func infoEntriesSortToTheEnd() {
        let plan = NodeNormalization.plan([
            input("到期時間：2027-03-30 23:42", "STOTIK", rank: 0),
            input("[vip1] ⑮香港︱Vless", "JSSR", rank: 1),
            input("剩余流量：89.98 GB", "JSSR", rank: 1),
            input("更新時間：2026-01-01 00:00", "STOTIK", rank: 0),
        ], rules: rules, now: Date(timeIntervalSince1970: 1_790_000_000),
           timeZone: TimeZone(identifier: "Asia/Shanghai")!)

        // 普通节点在前；入口；然后信息节点按 STOTIK(0) → JSSR(1)，
        // 同订阅内按更新→流量→重置→到期。
        #expect(plan.lines.map(\.index) == [1, 3, 3, 0, 2])
        #expect(plan.lines.map(\.name) == [
            "【JSSR】香港01",
            NodeNormalization.infoEntryName,
            "【INFO】STOTIK｜更新时间：2026-09-21 22:13",
            "【INFO】STOTIK｜到期时间：2027-03-30",
            "【INFO】JSSR｜剩余流量：89.98 GB",
        ])
        // 入口与第一条信息节点共用一个下标——它借的就是后者的连接参数。
        #expect(plan.lines[1].index == plan.lines[2].index)
    }

    @Test("更新时间显示订阅自己的更新时刻") func updateTimeUsesSubscriptionTimestamp() {
        let updated = Date(timeIntervalSince1970: 1_790_058_540)  // 2026-09-22 14:29 +0800
        let plan = NodeNormalization.plan(
            [input("更新時間：2020-01-01 00:00", "STOTIK", updatedAt: updated)],
            rules: rules, now: Date(timeIntervalSince1970: 0),
            timeZone: TimeZone(identifier: "Asia/Shanghai")!)

        // 机场名字里写的是它后端刷新的时间，这里要回答的是「这份列表有多新」。
        #expect(plan.names[0] == "【INFO】STOTIK｜更新时间：2026-09-22 14:29")
    }

    @Test("排除的条目留名但不输出") func excludedEntriesKeepANameButLeaveTheOutput() {
        let plan = NodeNormalization.plan([
            input("[vip1] ⑮香港︱Vless", "JSSR"),
            input("續約專用線路 - user.stotik.nl", "STOTIK", rank: 1),
        ], rules: rules)

        #expect(plan.lines.map(\.index) == [0])
        #expect(plan.names[1] == "【STOTIK】排除：續約專用線路 - user.stotik.nl")
    }

    @Test("同名信息节点只留一条") func duplicateInfoEntriesCollapse() {
        let plan = NodeNormalization.plan([
            input("剩余流量：89.98 GB", "JSSR"),
            input("剩餘流量：89.98 GB", "JSSR"),
        ], rules: rules)

        #expect(plan.lines.count == 2)  // 一条信息节点 + 它前面的入口
    }

    @Test("地区表为空时回落到内置表") func emptyRulesFallBackToDefaults() {
        let plan = NodeNormalization.plan([input("香港 01", "JSSR")], rules: [])

        #expect(plan.names == ["【JSSR】香港01"])
    }

    @Test("清洗规则表") func normalizesRuleTable() {
        let cleaned = NodeNormalization.normalized([
            .init(region: "  香港 ", keywords: [" 港 ", "", "HK"]),
            .init(region: "  ", keywords: ["X"]),
            .init(region: "空的", keywords: ["  "]),
        ])

        #expect(cleaned == [.init(region: "香港", keywords: ["港", "HK"])])
    }
}

/// 规范化接进配置生成之后，端口绑定和信息入口的落地。
@Suite("规范化与配置生成") struct NormalizedConfigurationTests {
    private func node(_ name: String, source: UUID) -> ProxyNode {
        ProxyNode(id: name, name: name, server: "\(name).example.com", serverPort: 443,
                  uuid: "11111111-1111-1111-1111-111111111111", flow: "xtls-rprx-vision",
                  serverName: "www.apple.com", publicKey: "pk", shortID: "sid",
                  fingerprint: "chrome", sourceIDs: [source], isEnabled: true)
    }

    /// 端口按节点名排，名字按规范化排——两套顺序不同，而每一行必须仍然
    /// 对着自己那个端口。错一位就是「点了香港走了美国」，且毫无征兆。
    @Test("重排之后每一行仍对着自己的端口") func reorderingKeepsPortsBound() throws {
        let sub = SubscriptionRecord(name: "JSSR", updatedAt: Date(timeIntervalSince1970: 1_790_058_540))
        let naming = NodeNaming(subscriptions: [sub], style: .normalized)
        // portMapping 按名字排序：「剩余流量…」排在「香港…」前面，于是信息节点占 7701。
        let nodes = [node("香港 01", source: sub.id), node("剩余流量：89.98 GB", source: sub.id)]

        let generated = try ConfigurationGenerator.generate(nodes: nodes, naming: naming)
        let mapped = ConfigurationGenerator.portMapping(nodes: nodes)
        let infoPort = try #require(mapped.first { $0.node.name.contains("剩余流量") }).localPort
        let hkPort = try #require(mapped.first { $0.node.name == "香港 01" }).localPort

        #expect(generated.surgeProxySection.contains("【JSSR】香港01 = socks5, 127.0.0.1, \(hkPort)"))
        #expect(generated.surgeProxySection
            .contains("【INFO】JSSR｜剩余流量：89.98 GB = socks5, 127.0.0.1, \(infoPort)"))
    }

    /// Surge 的 select 组默认选中第一项。信息组里第一项若是「更新时间：…」，
    /// 谁把这个组接到规则上，流量就断在一个连不通的假节点里。
    @Test("信息入口排在信息节点最前面") func infoEntryLeadsTheInfoSection() throws {
        let sub = SubscriptionRecord(name: "JSSR", updatedAt: Date(timeIntervalSince1970: 1_790_058_540))
        let naming = NodeNaming(subscriptions: [sub], style: .normalized)
        let nodes = [node("香港 01", source: sub.id), node("剩余流量：89.98 GB", source: sub.id)]

        let generated = try ConfigurationGenerator.generate(nodes: nodes, naming: naming)

        #expect(generated.policyNames == ["【JSSR】香港01",
                                          NodeNormalization.infoEntryName,
                                          "【INFO】JSSR｜剩余流量：89.98 GB"])
    }

    /// 一条信息节点都没有时不该凭空多出一行。
    @Test("没有信息节点就不补入口") func noInfoEntryWithoutInfoNodes() throws {
        let sub = SubscriptionRecord(name: "JSSR")
        let naming = NodeNaming(subscriptions: [sub], style: .normalized)

        let generated = try ConfigurationGenerator.generate(nodes: [node("香港 01", source: sub.id)],
                                                            naming: naming)

        #expect(generated.policyNames == ["【JSSR】香港01"])
    }

    /// 老配置里没有 nodeNamingStyle 这个键，解出来必须还是模板模式——
    /// 回落成规范化等于升级一次就把所有人策略组里存的名字全换掉。
    @Test("缺少命名方式的旧设置仍走模板") func legacySettingsStayOnTemplate() throws {
        let json = """
        {"singBoxBinaryPath":"/a","singBoxConfigPath":"/b","singBoxLogPath":"/c",
         "singBoxErrorLogPath":"/d","launchAgentPath":"/e","launchAgentLabel":"f"}
        """
        let settings = try JSONDecoder().decode(RouteBarSettings.self, from: Data(json.utf8))

        #expect(settings.nodeNamingStyle == .template)
        #expect(settings.nodeNameTemplate == NodeNaming.defaultTemplate)
        #expect(settings.regionRules == NodeNormalization.defaultRegionRules)
    }
}
