import Foundation

/// 生成的节点名怎么拼。
///
/// 名字曾经写死成 `RouteBar 01 - 香港01`。写死的代价是：同一台机器上跑两份 RouteBar、
/// 或者想按机场分组（`A机场 01 - …` / `B机场 01 - …`）时，只能改代码重编。
/// 现在规则是一份模板字符串，全局一条，每条订阅还可以各自覆盖。
///
/// **只影响交给 Surge 的那两种输出里的名字**（写配置与订阅地址用的是同一份）。sing-box 配置里的 `in-routebar-01` / `out-routebar-01`
/// 是内部标签，用户看不到，改它没有收益，反而要处理重名和非法字符——那两个 tag 必须
/// 唯一且稳定，否则入站与出站的一一绑定会串台。
public struct NodeNaming: Sendable, Equatable {
    /// 默认模板，与 1.6.1 及以前写死的名字逐字相同。
    ///
    /// 不能随版本改：Surge 策略组里存的是名字，默认值一变，所有人配置里的
    /// `sing-box 节点 = select, "RouteBar 01 - …"` 就会指向一批不存在的代理。
    public nonisolated static let defaultTemplate = "RouteBar {index} - {name}"

    public struct Placeholder: Sendable, Equatable {
        public let token: String
        public let summary: String

        public nonisolated init(token: String, summary: String) {
            self.token = token
            self.summary = summary
        }
    }

    /// 模板里能用的占位符。界面直接读这份列表，不各写一遍说明。
    public nonisolated static let placeholders: [Placeholder] = [
        .init(token: "{index}", summary: "两位序号，从 01 起"),
        .init(token: "{name}", summary: "机场给的节点名"),
        .init(token: "{subscription}", summary: "来源订阅名"),
        .init(token: "{port}", summary: "本机 SOCKS5 端口"),
    ]

    /// 全部订阅都没有自定义模板时用的那一条。
    private let globalTemplate: String
    /// 订阅各自的覆盖模板（去掉了空值——空等于「跟随全局」）。
    private let templatesBySource: [UUID: String]
    private let namesBySource: [UUID: String]
    /// 订阅在列表里的位置，用来在一个节点有多个来源时挑出唯一确定的那一个。
    private let rankBySource: [UUID: Int]
    /// 订阅最近一次更新成功的时刻，规范化模式下「更新时间」那条信息节点显示它。
    private let updatedAtBySource: [UUID: Date]
    /// 套模板还是走规范化。
    public let style: NodeNamingStyle
    /// 规范化用的地区表。模板模式下不读。
    public let regionRules: [RegionRule]

    public nonisolated static let `default` = NodeNaming()

    public nonisolated init(template: String = NodeNaming.defaultTemplate,
                            subscriptions: [SubscriptionRecord] = [],
                            style: NodeNamingStyle = .template,
                            regionRules: [RegionRule] = NodeNormalization.defaultRegionRules) {
        self.style = style
        self.regionRules = regionRules
        // 模板留空时回落到默认值：空模板会把每个节点都拼成空名字，写进 Surge 就是一批
        // `= socks5, …` 的残行，整段配置作废。
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        globalTemplate = trimmed.isEmpty ? NodeNaming.defaultTemplate : trimmed

        var templates: [UUID: String] = [:]
        var names: [UUID: String] = [:]
        var ranks: [UUID: Int] = [:]
        var updatedAt: [UUID: Date] = [:]
        for (offset, subscription) in subscriptions.enumerated() {
            names[subscription.id] = subscription.name
            ranks[subscription.id] = offset
            updatedAt[subscription.id] = subscription.updatedAt
            let override = (subscription.nodeNameTemplate ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !override.isEmpty { templates[subscription.id] = override }
        }
        templatesBySource = templates
        namesBySource = names
        rankBySource = ranks
        updatedAtBySource = updatedAt
    }

    public nonisolated init(settings: RouteBarSettings, subscriptions: [SubscriptionRecord]) {
        self.init(template: settings.nodeNameTemplate, subscriptions: subscriptions,
                  style: settings.nodeNamingStyle, regionRules: settings.regionRules)
    }

    /// 存进设置前先过这一道：清掉首尾空白，空模板存成默认值。
    ///
    /// 落盘一个空串虽然渲染时也会回落到默认，但界面读回来是空的，用户会以为
    /// 「我把它清掉了」而实际输出仍是 `RouteBar 01 - …`——存成默认值才所见即所得。
    public nonisolated static func normalized(_ template: String) -> String {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultTemplate : trimmed
    }

    // MARK: - 生成

    /// 一次算出整批名字。
    ///
    /// 必须整批算而不是逐个算：Surge 的 `[Proxy]` 段以名字为键，重名的行只有最后一条生效，
    /// 前面的会静默消失（节点数对不上，但没有任何报错）。而模板一旦不含 `{index}`
    /// 或 `{port}`，同名节点就必然撞车——所以去重只能在知道全部名字的地方做。
    public nonisolated func names(for mapped: [PortMappedNode]) -> [String] {
        plan(for: mapped).names
    }

    /// 整批规划：叫什么、按什么顺序输出、哪些不输出、要不要补一条信息入口。
    ///
    /// 模板模式下顺序就是输入顺序、一个都不排除——那条路径上「规划」退化成「起名字」，
    /// 但两种模式共用一个返回类型，`ConfigurationGenerator` 才不用分支处理。
    public nonisolated func plan(for mapped: [PortMappedNode], now: Date = .now) -> NormalizationPlan {
        switch style {
        case .template:
            return NormalizationPlan(names: templateNames(for: mapped),
                                     order: Array(mapped.indices),
                                     infoEntryIndex: nil)
        case .normalized:
            let inputs = mapped.map { item -> NormalizationInput in
                let source = primarySource(of: item.node)
                return NormalizationInput(
                    name: item.node.name,
                    sourceName: source.flatMap { namesBySource[$0] } ?? "",
                    sourceRank: source.flatMap { rankBySource[$0] } ?? .max,
                    sourceUpdatedAt: source.flatMap { updatedAtBySource[$0] })
            }
            let plan = NodeNormalization.plan(inputs, rules: regionRules, now: now)
            // 清洗同样要过：地区名和订阅名都是用户可改的，带上逗号或等号一样会拆坏 Surge 的行。
            let sanitized = plan.names.enumerated().map { NodeNaming.sanitize($1, index: $0 + 1) }
            return NormalizationPlan(names: sanitized, order: plan.order,
                                     infoEntryIndex: plan.infoEntryIndex)
        }
    }

    private nonisolated func templateNames(for mapped: [PortMappedNode]) -> [String] {
        var used: Set<String> = []
        return mapped.enumerated().map { offset, item in
            let base = render(index: offset + 1, node: item.node, port: item.localPort)
            var candidate = base
            var attempt = 0
            while used.contains(candidate) {
                attempt += 1
                // 序号在这一批里唯一，所以补上序号必然能收敛。
                let ordinal = NodeNaming.padded(offset + 1)
                candidate = attempt == 1 ? "\(base) \(ordinal)" : "\(base) \(ordinal)-\(attempt)"
            }
            used.insert(candidate)
            return candidate
        }
    }

    /// 节点 id → 输出名。列表要逐行显示「原名 / 输出名」，而名字只能整批算，
    /// 逐行现算会把 O(n) 变成 O(n²)，节点多时直接卡住一帧。
    public nonisolated func namesByNodeID(for mapped: [PortMappedNode]) -> [String: String] {
        Dictionary(zip(mapped.map(\.node.id), names(for: mapped)), uniquingKeysWith: { first, _ in first })
    }

    /// 原始订阅条目 id → 输出名。同一连接出现多次时，每条记录都有自己的端口和名称。
    public nonisolated func namesByEntryID(for mapped: [PortMappedNode]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: zip(mapped.map(\.node.entryID), names(for: mapped)).map { ($0, $1) })
    }

    /// 一次试跑的结果：每个节点原来叫什么、按这份模板会叫什么。
    ///
    /// 「保存了才知道长什么样」是这个功能最难用的地方——模板是即时生效的，
    /// 存下去就等于把 Surge 里的名字全改了。所以试跑要能在不保存的前提下做。
    public struct PreviewRow: Sendable, Equatable, Identifiable {
        public let id: String
        public let originalName: String
        public let outputName: String
        public let localPort: Int

        public nonisolated init(id: String, originalName: String, outputName: String, localPort: Int) {
            self.id = id
            self.originalName = originalName
            self.outputName = outputName
            self.localPort = localPort
        }
    }

    /// 按给定模板试跑全部启用节点。
    ///
    /// 一个节点都没有时用造出来的示例，`isSample` 会是真——否则刚装上还没添加订阅的人
    /// 改模板等于盲改，而一片空白也分不清是「模板有问题」还是「本来就没节点」。
    public nonisolated static func previewRows(template: String,
                                               subscriptions: [SubscriptionRecord],
                                               mapped: [PortMappedNode],
                                               style: NodeNamingStyle = .template,
                                               regionRules: [RegionRule] = NodeNormalization.defaultRegionRules)
        -> (rows: [PreviewRow], isSample: Bool) {
        let naming = NodeNaming(template: template, subscriptions: subscriptions,
                                style: style, regionRules: regionRules)
        let isSample = mapped.isEmpty
        let sample = isSample ? sampleNodes(subscriptions: subscriptions, style: style) : mapped
        let plan = naming.plan(for: sample)

        // 按**输出顺序**列，不按输入顺序：规范化会把信息节点挪到最后、把续约线路踢掉，
        // 而试跑要回答的就是「Surge 到底会收到什么」——照输入顺序列等于没回答。
        var rows = plan.order.map { index in
            PreviewRow(id: sample[index].node.entryID, originalName: sample[index].node.name,
                       outputName: plan.names[index], localPort: sample[index].localPort)
        }
        if let first = plan.infoEntryIndex, let at = plan.order.firstIndex(of: first) {
            rows.insert(PreviewRow(id: "info-entry", originalName: "",
                                   outputName: NodeNormalization.infoEntryName,
                                   localPort: sample[first].localPort), at: at)
        }
        // 不输出的排在最末尾。名字里已经写着「排除：」，位置再靠后一点就不会被当成正常结果。
        let excluded = Set(plan.order)
        rows += sample.indices.filter { !excluded.contains($0) }.map { index in
            PreviewRow(id: sample[index].node.entryID, originalName: sample[index].node.name,
                       outputName: plan.names[index], localPort: sample[index].localPort)
        }
        return (rows, isSample)
    }

    /// 设置页那一行的简短预览：只取前几个。
    public nonisolated static func preview(template: String,
                                           subscriptions: [SubscriptionRecord],
                                           mapped: [PortMappedNode],
                                           style: NodeNamingStyle = .template,
                                           regionRules: [RegionRule] = NodeNormalization.defaultRegionRules,
                                           limit: Int = 2) -> [String] {
        previewRows(template: template, subscriptions: subscriptions, mapped: mapped,
                    style: style, regionRules: regionRules)
            .rows.prefix(limit).map(\.outputName)
    }

    /// 还没有任何节点时拿来试跑的假节点。
    ///
    /// 规范化模式下多给一条订阅信息：它和普通节点走的是两条完全不同的规则，
    /// 只看普通节点的话，用户改完地区表按下保存，才会第一次看见 `【INFO】…` 长什么样。
    private nonisolated static func sampleNodes(subscriptions: [SubscriptionRecord],
                                                style: NodeNamingStyle = .template) -> [PortMappedNode] {
        let source = subscriptions.first.map { [$0.id] } ?? []
        let names = style == .normalized
            ? ["香港 01", "东京 02", "剩余流量：89.98 GB"]
            : ["香港 01", "东京 02"]
        return names.enumerated().map { offset, name in
            PortMappedNode(
                node: ProxyNode(id: "sample-\(offset)", name: name, server: "example.com", serverPort: 443,
                                uuid: "", flow: "", serverName: "", publicKey: "", shortID: "",
                                fingerprint: "", sourceIDs: source, isEnabled: true),
                localPort: 7701 + offset)
        }
    }

    private nonisolated func render(index: Int, node: ProxyNode, port: Int) -> String {
        let source = primarySource(of: node)
        let template = source.flatMap { templatesBySource[$0] } ?? globalTemplate
        let text = template
            .replacingOccurrences(of: "{index}", with: NodeNaming.padded(index))
            .replacingOccurrences(of: "{name}", with: node.name)
            .replacingOccurrences(of: "{subscription}", with: source.flatMap { namesBySource[$0] } ?? "")
            .replacingOccurrences(of: "{port}", with: String(port))
        return NodeNaming.sanitize(text, index: index)
    }

    /// 同一个节点可能来自多个订阅（去重后来源是合并的），命名只能认一个。
    ///
    /// 取订阅列表里靠前的那一个——顺序是用户自己排的，看得见也稳定；
    /// 换成「第一个设了自定义模板的来源」会让名字随着某条订阅改模板而整体跳动。
    private nonisolated func primarySource(of node: ProxyNode) -> UUID? {
        node.sourceIDs
            .compactMap { id in rankBySource[id].map { (id, $0) } }
            .min { $0.1 < $1.1 }?.0
    }

    private nonisolated static func padded(_ index: Int) -> String {
        String(format: "%02d", index)
    }

    /// 逗号、等号、引号和换行在 Surge 配置里是语法字符，名字里带这些会把整行拆坏。
    /// 节点名来自机场、订阅名和模板来自用户，三者都不可信，所以清洗放在拼完之后。
    private nonisolated static func sanitize(_ text: String, index: Int) -> String {
        let safe = text.replacingOccurrences(of: "[,=\"'\\r\\n]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // 模板只写了 `{subscription}` 而节点没有来源时，拼出来会是空串。
        // 空名字同样会毁掉这一行，兜一个永远可用的。
        return safe.isEmpty ? "RouteBar \(padded(index))" : safe
    }
}
