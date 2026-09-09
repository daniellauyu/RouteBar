import Foundation
import Testing

@testable import RouteBarDomain

@Suite("列表序号")
struct NodeOrderingTests {
    /// 序号取的是节点在完整列表里的位置，所以「完整列表」的顺序必须和端口顺序一致。
    ///
    /// 不一致时的样子（真机上出现过）：左边一列是 76、71、72、73…，而同一行的端口是
    /// 7701、7702、7703…，生成名是 JSSR-01、JSSR-02、JSSR-03——三个数字互相打架。
    @Test func listOrderMatchesPortOrder() {
        let state = makeState()
        let enabled = state.displayedNodes.filter(\.effectiveEnabled)

        // 第 N 个启用节点就该占第 N 个端口。
        for (offset, item) in enabled.enumerated() {
            #expect(item.localPort == 7701 + offset,
                    "第 \(offset + 1) 个启用节点的端口应是 \(7701 + offset)，实际 \(String(describing: item.localPort))")
        }
    }

    /// 两个来源的节点按名称交错，而不是按订阅堆在一起。
    ///
    /// 名字用 ASCII：`localizedStandardCompare` 认当前语言环境，中文按拼音排
    /// （东京 → 香港 → 新加坡），把那个顺序钉进断言的话，换一台英文环境的机器就挂了。
    /// 上面几条断言比的是「列表顺序」与「端口顺序」是否一致，两边用的是同一个比较函数，
    /// 所以无论什么语言环境都成立——这里只补一条「确实交错了」。
    @Test func nodesFromDifferentSubscriptionsInterleaveByName() {
        let names = makeState().displayedNodes.map(\.node.name)
        #expect(names == ["Alpha 01", "Bravo 01", "Charlie 01", "Charlie 02"])
    }

    /// 端口分配与列表用的是同一个比较函数，不是各排各的。
    @Test func portMappingUsesTheSameOrderAsTheList() {
        let state = makeState()
        let listed = state.displayedNodes.filter(\.effectiveEnabled).map(\.node.entryID)
        let mapped = state.mappedNodes.map(\.node.entryID)
        #expect(listed == mapped)
    }

    /// 停用的节点没有端口，但仍占一个序号——序号要指向节点本身，
    /// 关掉一个就让后面全部重排的话，「第 5 个」隔一会儿就换人了。
    @Test func disabledNodesKeepTheirPlaceButGetNoPort() {
        var subscription = SubscriptionRecord(name: "A")
        subscription.nodes = [node("Alpha 01", enabled: false), node("Bravo 01", enabled: true)]
        let state = AppViewState(
            subscriptions: [subscription], serviceState: .stopped,
            environment: RouteBarEnvironmentReport(paths: RuntimePaths()) { _ in true },
            settings: .defaults(), autoUpdatePaused: false,
            mappedNodes: ConfigurationGenerator.portMapping(nodes: subscription.nodes))

        #expect(state.displayedNodes.count == 2)
        #expect(state.displayedNodes[0].localPort == nil)
        #expect(state.displayedNodes[1].localPort == 7701)
    }

    /// 两条订阅，各自内部的顺序都和名称顺序不同 —— 这正是序号跳号的来源。
    private func makeState() -> AppViewState {
        var first = SubscriptionRecord(name: "JSSR")
        first.nodes = [node("Charlie 02"), node("Alpha 01")]
        var second = SubscriptionRecord(name: "别的机场")
        second.nodes = [node("Charlie 01"), node("Bravo 01")]
        let subscriptions = [first, second]
        let mapped = ConfigurationGenerator.portMapping(nodes: subscriptions.flatMap(\.nodes))
        return AppViewState(
            subscriptions: subscriptions, serviceState: .stopped,
            environment: RouteBarEnvironmentReport(paths: RuntimePaths()) { _ in true },
            settings: .defaults(), autoUpdatePaused: false, mappedNodes: mapped)
    }

    private func node(_ name: String, enabled: Bool = true) -> ProxyNode {
        ProxyNode(id: "id-" + name, entryID: "entry-" + name, name: name,
                  server: "a.example.com", serverPort: 443, uuid: "u", flow: "",
                  serverName: "a.example.com", publicKey: "", shortID: "",
                  fingerprint: "chrome", sourceIDs: [], isEnabled: enabled)
    }
}

@Suite("落地探测")
struct NodeGeoTests {
    /// 真机上 Cloudflare 返回的样子，逐字抄下来。
    private let sample = """
    fl=98f77
    h=www.cloudflare.com
    ip=203.0.113.7
    ts=1757380000.123
    visit_scheme=https
    uag=RouteBar (macOS)
    colo=SIN
    sliver=none
    http=http/2
    loc=SG
    tls=TLSv1.3
    sni=plaintext
    warp=off
    gateway=off
    """

    @Test func parsesExitAddressAndCountry() throws {
        let record = try #require(CloudflareTrace.parse(sample))
        #expect(record.outcome == .success)
        #expect(record.ip == "203.0.113.7")
        #expect(record.countryCode == "SG")
    }

    @Test func rejectsResponsesWithoutAnExitAddress() {
        // 被中间设备换成门户页时，正文里可能什么都有，就是没有 ip。
        // 这种响应里的 loc 不可信，整次探测必须判失败。
        #expect(CloudflareTrace.parse("<html><body>Portal</body></html>") == nil)
        #expect(CloudflareTrace.parse("loc=SG\ncolo=SIN") == nil)
        #expect(CloudflareTrace.parse("") == nil)
        #expect(CloudflareTrace.parse("ip=") == nil)
    }

    @Test func keepsTheAddressWhenTheCountryIsMissingOrUnknown() throws {
        // 半个答案也比把整次探测判成失败有用。
        let missing = try #require(CloudflareTrace.parse("ip=198.51.100.9"))
        #expect(missing.outcome == .success)
        #expect(missing.countryCode.isEmpty)

        let unknown = try #require(CloudflareTrace.parse("ip=198.51.100.9\nloc=XX"))
        #expect(unknown.countryCode.isEmpty)

        let malformed = try #require(CloudflareTrace.parse("ip=198.51.100.9\nloc=SGP"))
        #expect(malformed.countryCode.isEmpty)
    }

    @Test func firstValueWinsForRepeatedKeys() throws {
        let record = try #require(CloudflareTrace.parse("ip=203.0.113.7\nip=10.0.0.1\nloc=JP"))
        #expect(record.ip == "203.0.113.7")
    }

    @Test func derivesFlagsFromTheCountryCodeWithoutATable() {
        // 两个字母各自映射到区域指示符号，所以任何合法两位码都成立。
        #expect(GeoRecord(outcome: .success, countryCode: "SG").flag == "🇸🇬")
        #expect(GeoRecord(outcome: .success, countryCode: "JP").flag == "🇯🇵")
        #expect(GeoRecord(outcome: .success, countryCode: "hk").flag == "🇭🇰")
    }

    @Test func producesNoFlagForCodesThatAreNotTwoLetters() {
        #expect(GeoRecord(outcome: .success, countryCode: "").flag.isEmpty)
        #expect(GeoRecord(outcome: .success, countryCode: "S").flag.isEmpty)
        #expect(GeoRecord(outcome: .success, countryCode: "S1").flag.isEmpty)
        #expect(GeoRecord(outcome: .success, countryCode: "SGP").flag.isEmpty)
    }

    @Test func labelFallsBackToTheExitAddressWhenTheRegionIsUnknown() {
        let noRegion = GeoRecord(outcome: .success, ip: "198.51.100.9", countryCode: "")
        #expect(noRegion.label() == "198.51.100.9")
    }

    @Test func unrecognisedRegionCodesAreShownVerbatim() {
        // 没见过的两位码本身就是信息，换成「未知」反而把它抹掉了。
        // ZZ 尤其要挡住：它是 CLDR 的占位码，系统会把它翻成「未知地区」这样一句
        // 正经的地区名，看着像探测成功了（Locale.Region("ZZ").isISORegion 就是真）。
        let placeholder = GeoRecord(outcome: .success, ip: "198.51.100.9", countryCode: "ZZ")
        #expect(placeholder.regionName(locale: Locale(identifier: "en_US")) == "ZZ")

        let bogus = GeoRecord(outcome: .success, ip: "198.51.100.9", countryCode: "QQ")
        #expect(bogus.regionName(locale: Locale(identifier: "en_US")) == "QQ")
    }

    @Test func resolvesRealRegionsInBothLanguages() {
        let record = GeoRecord(outcome: .success, ip: "203.0.113.7", countryCode: "SG")
        #expect(record.regionName(locale: Locale(identifier: "zh_CN")) == "新加坡")
        #expect(record.regionName(locale: Locale(identifier: "en_US")) == "Singapore")
        #expect(record.label(locale: Locale(identifier: "zh_CN")) == "🇸🇬 新加坡")
    }

    @Test func carriesLandingResultsAcrossASubscriptionRefresh() {
        // 出口不会因为订阅刷新而改变，不搬运的话每次更新都要把全部节点重探一遍。
        let source = UUID()
        let geo = GeoRecord(outcome: .success, ip: "203.0.113.7", countryCode: "SG")
        let previous = [makeNode(id: "a", sourceID: source, geo: geo)]
        let refreshed = [makeNode(id: "a", sourceID: source, geo: nil)]

        let carried = NodeCatalog.carryPersistedState(from: previous, to: refreshed)
        #expect(carried[0].geo?.ip == "203.0.113.7")
        #expect(carried[0].geo?.countryCode == "SG")
    }

    @Test func decodesNodesWrittenBeforeLandingDetectionExisted() throws {
        // geo 是可选字段，老 state.json 里没有这个键也必须解得出来。
        let json = """
        {"id":"a","entryID":"a","name":"香港01","server":"a.example.com","serverPort":443,\
        "uuid":"u","flow":"","serverName":"a.example.com","publicKey":"","shortID":"",\
        "fingerprint":"chrome","sourceIDs":[],"isEnabled":true}
        """
        let node = try JSONDecoder().decode(ProxyNode.self, from: Data(json.utf8))
        #expect(node.geo == nil)
        #expect(node.name == "香港01")
    }

    private func makeNode(id: String, sourceID: UUID, geo: GeoRecord?) -> ProxyNode {
        ProxyNode(id: id, entryID: id, name: "N", server: "a.example.com", serverPort: 443,
                  uuid: "u", flow: "", serverName: "a.example.com", publicKey: "", shortID: "",
                  fingerprint: "chrome", sourceIDs: [sourceID], isEnabled: true, geo: geo)
    }
}
