import Foundation

/// 节点名的生成方式。
public enum NodeNamingStyle: String, Codable, CaseIterable, Sendable {
    /// 模板拼接，见 `NodeNaming`。1.6.1 以来唯一的方式，也是解码缺失时的回落值。
    case template
    /// 规范化：把机场原始名压成 `【来源】地区NN`，并把混在节点里的订阅信息单独归类。
    case normalized
    /// 跑用户自己写的 JS `operator`，见 `NodeScript`。
    ///
    /// 规范化那一套是把流程写死在代码里，只有地区表可配；脚本是把整个流程交出去。
    /// 两者并存而不是用脚本取代规范化：绝大多数人不需要写脚本，而一个空白的编辑器
    /// 比一张填好的地区表难上手得多。
    case script

    public nonisolated var label: String {
        switch self {
        case .template: "模板"
        case .normalized: "规范化"
        case .script: "脚本"
        }
    }
}

/// 一条地区识别规则：命中任意一个关键词就算这个地区。
///
/// 顺序有意义——**先匹配到的先算**。`美国` 必须排在 `俄罗斯` 之类含 `US` 子串的地区之前，
/// 否则 `RUSSIA` 会先被 `US` 抢走。规则表整体可在网页控制台编辑，所以顺序也由用户掌握。
public struct RegionRule: Codable, Equatable, Sendable, Identifiable {
    public var region: String
    public var keywords: [String]

    public nonisolated var id: String { region }

    public nonisolated init(region: String, keywords: [String]) {
        self.region = region
        self.keywords = keywords
    }
}

/// 把机场给的原始节点名压成 `【来源】地区NN`，并把混在节点列表里的订阅信息
/// （流量、到期、更新时间、重置日）挑出来单独命名。
///
/// 为什么要做这件事：机场的节点名是给人看的广告位——`[vip1] ⑮香港︱Vless ｜×1倍率｜限速100M`
/// 这种名字里，真正有用的信息只有「香港」两个字。而 Surge 的策略组靠 `policy-regex-filter`
/// 按名字分组，名字越花，正则越难写、越容易漏。压成固定格式之后，`(港)` 这样的正则
/// 就能稳定命中，且机场改名不会让分组失效。
///
/// 订阅信息为什么要留着而不是丢掉：机场把「剩余流量」「到期时间」当作节点塞进订阅里，
/// 它们指向的端口根本连不通。留着但改名成 `【INFO】…`，Surge 那边就能用一条
/// `policy-regex-filter=^【INFO】` 把它们收进一个单独的组——既能随时看到流量余额，
/// 又不会让它们混进 url-test 组里被反复测速、反复失败。
///
/// 纯字符串计算，所以放 Domain：地区认错、信息节点漏判都是安静的错误——Surge 那边
/// 只会表现为「某个组少了几个节点」，不报错，必须能用测试钉住。
public enum NodeNormalization {
    /// 信息节点统一的前缀。Surge 侧 `policy-regex-filter=^【INFO】` 认的就是它。
    public nonisolated static let infoPrefix = "【INFO】"
    /// 合成的信息入口名。
    public nonisolated static let infoEntryName = "【INFO】查看订阅信息"
    /// 认不出地区时落到这里。
    public nonisolated static let fallbackRegion = "小众"

    // MARK: - 地区规则

    /// 默认地区表。
    ///
    /// 两个字母的英文代码（US、JP、HK…）按**单词边界**匹配，其余按子串匹配——否则
    /// `US` 会命中 `RUSSIA`、`ID` 会命中 `MADRID`，而这种错分在 Surge 那边只表现为
    /// 「某个地区组里混进了不相干的节点」，不会报错。边界的定义是「前后不是 ASCII 字母数字」，
    /// 于是 `美国US节点` 和 `RS-VT` 都算命中，`RUSSIA` 不算。
    public nonisolated static let defaultRegionRules: [RegionRule] = [
        .init(region: "美国", keywords: ["美国", "美國", "UNITED STATES", "AMERICA", "USA", "US"]),
        .init(region: "日本", keywords: ["日本", "JAPAN", "JP"]),
        .init(region: "香港", keywords: ["香港", "HONG KONG", "HONGKONG", "HK"]),
        .init(region: "台湾", keywords: ["台湾", "台灣", "臺灣", "臺湾", "TAIWAN", "TW"]),
        .init(region: "新加坡", keywords: ["新加坡", "獅城", "狮城", "SINGAPORE", "SG"]),
        .init(region: "韩国", keywords: ["韩国", "韓國", "韩", "韓", "SOUTH KOREA", "KOREA", "KR"]),
        .init(region: "德国", keywords: ["德国", "德國", "GERMANY", "DE"]),
        .init(region: "英国", keywords: ["英国", "英國", "UNITED KINGDOM", "BRITAIN", "ENGLAND", "UK", "GB"]),
        .init(region: "俄罗斯", keywords: ["俄罗斯", "俄羅斯", "RUSSIA", "RU", "RS"]),
        .init(region: "越南", keywords: ["越南", "VIETNAM", "VN"]),
        .init(region: "印尼", keywords: ["印尼", "印度尼西亚", "印度尼西亞", "INDONESIA", "ID"]),
        .init(region: "菲律宾", keywords: ["菲律宾", "菲律賓", "PHILIPPINES", "PH"]),
        .init(region: "泰国", keywords: ["泰国", "泰國", "THAILAND", "TH"]),
        .init(region: "马来西亚", keywords: ["马来西亚", "馬來西亞", "MALAYSIA", "MY"]),
        .init(region: "澳大利亚", keywords: ["澳大利亚", "澳大利亞", "澳洲", "AUSTRALIA", "AU"]),
        .init(region: "加拿大", keywords: ["加拿大", "CANADA", "CA"]),
        .init(region: "法国", keywords: ["法国", "法國", "FRANCE", "FR"]),
        .init(region: "荷兰", keywords: ["荷兰", "荷蘭", "NETHERLANDS", "HOLLAND", "NL"]),
    ]

    /// 存进设置前先过这一道：去掉空地区名、空关键词和整条空规则。
    ///
    /// 网页表格里删到一行只剩空格是常态，原样存下去会让那条规则匹配所有名字
    /// （空关键词是任何字符串的子串），把后面的规则全部挡死。
    public nonisolated static func normalized(_ rules: [RegionRule]) -> [RegionRule] {
        rules.compactMap { rule in
            let region = rule.region.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !region.isEmpty else { return nil }
            let keywords = rule.keywords
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !keywords.isEmpty else { return nil }
            return RegionRule(region: region, keywords: keywords)
        }
    }

    /// 按规则表认地区。认不出来返回 `小众`。
    public nonisolated static func region(of name: String, rules: [RegionRule]) -> String {
        let haystack = name.uppercased()
        for rule in rules where rule.keywords.contains(where: { matches(haystack, keyword: $0) }) {
            return rule.region
        }
        return fallbackRegion
    }

    /// 关键词是否出现在名字里。
    ///
    /// 两个字母的纯 ASCII 关键词要求前后都不是 ASCII 字母数字，其余直接找子串。
    /// 自己判边界而不是用 `\b`：`NSRegularExpression` 的 `\b` 把中日韩文字也算作单词字符，
    /// 于是 `美国US节点` 里 `S` 和 `节` 之间没有边界，`\bUS\b` 匹配不上——而这正是
    /// 机场节点名最常见的写法。
    private nonisolated static func matches(_ haystack: String, keyword: String) -> Bool {
        let needle = keyword.uppercased()
        guard !needle.isEmpty else { return false }
        let isShortCode = needle.count <= 2 && needle.allSatisfy { $0.isASCII && $0.isLetter }
        guard isShortCode else { return haystack.contains(needle) }

        var searchStart = haystack.startIndex
        while let found = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            let beforeOK = found.lowerBound == haystack.startIndex
                || !isASCIIWord(haystack[haystack.index(before: found.lowerBound)])
            let afterOK = found.upperBound == haystack.endIndex
                || !isASCIIWord(haystack[found.upperBound])
            if beforeOK && afterOK { return true }
            guard found.upperBound < haystack.endIndex else { return false }
            searchStart = haystack.index(after: found.lowerBound)
        }
        return false
    }

    private nonisolated static func isASCIIWord(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }

    // MARK: - 订阅信息节点

    /// 机场塞在订阅里的那几类「不是节点的节点」。
    ///
    /// `order` 决定它们在 Surge 那个组里的排列：先看订阅什么时候更新的，再看还剩多少流量、
    /// 什么时候重置、什么时候到期——按一次查看时的关注顺序排，而不是按字母序。
    public enum InfoKind: String, CaseIterable, Sendable {
        case update, traffic, reset, expire

        public nonisolated var order: Int {
            switch self {
            case .update: 1
            case .traffic: 2
            case .reset: 3
            case .expire: 4
            }
        }

        /// 输出时统一用简体，机场写繁体也归到同一个名字下。
        public nonisolated var label: String {
            switch self {
            case .update: "更新时间"
            case .traffic: "剩余流量"
            case .reset: "下次重置"
            case .expire: "到期时间"
            }
        }

        nonisolated var keywords: [String] {
            switch self {
            case .update: ["更新时间", "更新時間"]
            case .traffic: ["剩余流量", "剩餘流量", "流量剩余", "流量剩餘"]
            // 「距离下次重置剩余：13 天」这类写法里 `剩余` 在冒号前面，靠 `重置` 认。
            case .reset: ["下次重置", "重置剩余", "重置剩餘", "流量重置"]
            case .expire: ["到期时间", "到期時間", "套餐到期", "到期日期"]
            }
        }
    }

    /// 这个名字是不是订阅信息；是的话属于哪一类。
    ///
    /// 判定顺序按 `InfoKind.allCases`，而 `expire` 排在最后——「套餐到期时间」同时含
    /// 「到期时间」和「套餐到期」，但不含其它三类的关键词，谁先判都一样；真正需要固定顺序的
    /// 是将来往表里加词的时候，有个确定的答案比「看哪条先写」强。
    public nonisolated static func infoKind(of name: String) -> InfoKind? {
        InfoKind.allCases.first { kind in
            kind.keywords.contains { name.contains($0) }
        }
    }

    /// 机场的「续约专用线路」之类：是真能连的代理，但连上去只会看到付款页。
    /// 留在列表里只会污染 url-test 组，直接不输出。
    public nonisolated static func isRenewalEntry(_ name: String) -> Bool {
        let keywords = ["续约专用线路", "續約專用線路", "续费专用线路", "續費專用線路",
                        "续约线路", "續約線路", "续费线路", "續費線路", "续费专用", "續費專用"]
        return keywords.contains { name.contains($0) }
    }

    /// 信息节点的取值。
    ///
    /// `update` 用的是**生成这一份列表的时刻**，不是机场自己写的更新时间：机场那个值是它
    /// 上次刷新后端的时间，而这里要回答的是「Surge 手上这份节点列表有多新」——后者才是
    /// 排查「为什么新买的节点没出现」时要看的。
    public nonisolated static func infoValue(of name: String, kind: InfoKind, now: Date,
                                             timeZone: TimeZone = .current) -> String {
        switch kind {
        case .update:
            return timestamp(now, timeZone: timeZone)
        case .expire:
            return date(in: name, timeZone: timeZone) ?? valueAfterColon(in: name) ?? "unknown"
        case .traffic, .reset:
            return valueAfterColon(in: name) ?? "unknown"
        }
    }

    /// 冒号后面那一截。全角半角都认，空白压成单个空格。
    private nonisolated static func valueAfterColon(in name: String) -> String? {
        guard let colon = name.firstIndex(where: { $0 == "：" || $0 == ":" }) else { return nil }
        let value = name[name.index(after: colon)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return value.isEmpty ? nil : value
    }

    /// 从名字里抠出一个日期，统一成 `2027-02-05`。
    /// `2027-03-30` / `2027/3/30` / `2027.3.30` / `2027年3月30日` 都认。
    private nonisolated static func date(in name: String, timeZone: TimeZone) -> String? {
        let pattern = "([0-9]{4})[-/.年]([0-9]{1,2})[-/.月]([0-9]{1,2})"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let year = range(match, 1, in: name),
              let month = range(match, 2, in: name),
              let day = range(match, 3, in: name) else { return nil }
        return "\(year)-\(pad(month))-\(pad(day))"
    }

    private nonisolated static func range(_ match: NSTextCheckingResult, _ index: Int, in name: String) -> String? {
        Range(match.range(at: index), in: name).map { String(name[$0]) }
    }

    private nonisolated static func pad(_ text: String) -> String {
        text.count >= 2 ? text : "0" + text
    }

    private nonisolated static func timestamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - 组装

    /// 信息节点的完整输出名：`【INFO】STOTIK｜剩余流量：89.98 GB`
    public nonisolated static func infoName(source: String, kind: InfoKind, value: String) -> String {
        let prefix = source.isEmpty ? infoPrefix : "\(infoPrefix)\(source)｜"
        return "\(prefix)\(kind.label)：\(value)"
    }

    /// 普通节点的完整输出名：`【JSSR】香港01`
    public nonisolated static func nodeName(source: String, region: String, index: Int) -> String {
        let prefix = source.isEmpty ? "" : "【\(source)】"
        return "\(prefix)\(region)\(String(format: "%02d", index))"
    }
}

// MARK: - 整批规划

/// 规范化的一个输入条目。
///
/// 只带名字和来源，不带端口和协议：规范化只决定「叫什么、排第几、要不要输出」，
/// 端口绑定是 `ConfigurationGenerator` 的事，两者分开才好各自测。
public struct NormalizationInput: Sendable, Equatable {
    /// 机场给的原始节点名。
    public let name: String
    /// 来源订阅名。节点没有来源时是空串。
    public let sourceName: String
    /// 来源订阅在列表里的位置，决定信息节点的排列顺序。没有来源时排最后。
    public let sourceRank: Int
    /// 来源订阅最近一次**更新成功**的时刻，`更新时间` 那条信息节点显示的就是它。
    ///
    /// 机场自己也会在订阅里塞一个「更新時間」节点，但那是它后端刷新的时间，与「Surge
    /// 手上这份列表有多新」是两回事——而后者才是排查「新买的节点怎么没出现」时要看的。
    /// 取不到时（订阅从没成功过）回落到生成时刻。
    public let sourceUpdatedAt: Date?

    public nonisolated init(name: String, sourceName: String, sourceRank: Int = .max,
                            sourceUpdatedAt: Date? = nil) {
        self.name = name
        self.sourceName = sourceName
        self.sourceRank = sourceRank
        self.sourceUpdatedAt = sourceUpdatedAt
    }
}

/// 一次规范化的结果。
public struct NormalizationPlan: Sendable, Equatable {
    /// 输出的一行：一个名字，绑定到某个输入下标（端口从那里取）。
    public struct Line: Sendable, Equatable {
        public let name: String
        /// 输入下标。**同一个下标可以出现在多行里**——合成的信息入口就是借第一条
        /// 信息节点的连接参数，两行指向同一个端口。
        public let index: Int

        public nonisolated init(name: String, index: Int) {
            self.name = name
            self.index = index
        }
    }

    /// 与输入**逐位对齐**的输出名，含不输出的那些。
    ///
    /// 界面按这个显示「这个节点叫什么、有没有进 Surge」。真正决定输出的是 `lines`：
    /// 名字与端口的绑定放在那里，而不是靠两个数组的下标默契——错一位整份配置串台，
    /// 而这种错位没有任何征兆。
    public let names: [String]
    /// 输出的全部行，顺序即 Surge 里的顺序。不输出的条目不出现在这里。
    public let lines: [Line]

    public nonisolated init(names: [String], lines: [Line]) {
        self.names = names
        self.lines = lines
    }

    /// 便利构造：一批下标按原名直接成行，不重复、不改名。
    public nonisolated init(names: [String], order: [Int]) {
        self.init(names: names, lines: order.map { Line(name: names[$0], index: $0) })
    }
}

extension NodeNormalization {
    /// 整批规划：谁叫什么、按什么顺序输出、哪些不输出。
    ///
    /// 必须整批算而不是逐个算。两个原因：编号是按「来源 + 地区」累计的，逐个算不知道
    /// 前面已经用到第几号；而 Surge 的 `[Proxy]` 段以名字为键，重名的行只有最后一条生效、
    /// 前面的静默消失——查重同样只能在看得见全部名字的地方做。
    public nonisolated static func plan(_ inputs: [NormalizationInput],
                                        rules: [RegionRule] = defaultRegionRules,
                                        now: Date = .now,
                                        timeZone: TimeZone = .current) -> NormalizationPlan {
        let effectiveRules = rules.isEmpty ? defaultRegionRules : rules

        var names = [String](repeating: "", count: inputs.count)
        var normalOrder: [Int] = []
        var infoEntries: [(index: Int, rank: Int, order: Int)] = []
        var counters: [String: Int] = [:]
        var used: Set<String> = []

        for (index, input) in inputs.enumerated() {
            let raw = input.name.trimmingCharacters(in: .whitespacesAndNewlines)

            // 续约线路先判：它的名字里常带地区（「续费专用线路 - 香港」），
            // 放在地区识别后面会先被当成普通节点编进号，白占一个序号。
            if isRenewalEntry(raw) {
                names[index] = excludedName(source: input.sourceName, original: raw)
                continue
            }

            if let kind = infoKind(of: raw) {
                let value = infoValue(of: raw, kind: kind,
                                      now: input.sourceUpdatedAt ?? now, timeZone: timeZone)
                let name = infoName(source: input.sourceName, kind: kind, value: value)
                // 同名信息节点只留一条。机场偶尔会把同一条信息重复塞几遍，
                // 而 Surge 那边重名行会互相覆盖，留着只是让组里多出几条看不见的死项。
                guard !used.contains(name) else {
                    names[index] = excludedName(source: input.sourceName, original: raw)
                    continue
                }
                used.insert(name)
                names[index] = name
                infoEntries.append((index, input.sourceRank, kind.order))
                continue
            }

            let region = region(of: raw, rules: effectiveRules)
            let key = "\(input.sourceName)\u{1F}\(region)"
            let next = (counters[key] ?? 0) + 1
            counters[key] = next
            names[index] = unique(nodeName(source: input.sourceName, region: region, index: next),
                                  used: &used)
            normalOrder.append(index)
        }

        // 信息节点排到最后，按「订阅顺序 → 信息类型」排。
        //
        // 排在最后是为了让 `🌏 手动切换` 这类收全部节点的组里，真正能用的节点排在前面；
        // Surge 的组按给定顺序展示，信息节点混在中间会把列表割得很碎。
        let sortedInfo = infoEntries
            .sorted { ($0.rank, $0.order, $0.index) < ($1.rank, $1.order, $1.index) }
            .map(\.index)

        var lines = normalOrder.map { NormalizationPlan.Line(name: names[$0], index: $0) }
        // 信息入口：Surge 不接受只有名字、没有连接参数的策略项，所以借第一条信息节点的端口。
        //
        // 为什么要多这一条：`💡 订阅信息` 组按 `^【INFO】` 收节点，而 Surge 的 select 组
        // 默认选中第一项——没有这条入口时，默认选中的会是「更新时间：…」这种连不通的假节点，
        // 一旦有人手滑把这个组设成某条规则的出口，流量就直接断在那里。
        if let first = sortedInfo.first {
            lines.append(NormalizationPlan.Line(name: infoEntryName, index: first))
        }
        lines += sortedInfo.map { NormalizationPlan.Line(name: names[$0], index: $0) }

        return NormalizationPlan(names: names, lines: lines)
    }

    /// 不输出的条目在界面上叫什么。带上原名，否则用户只看到「少了一个节点」却不知道少了哪个。
    private nonisolated static func excludedName(source: String, original: String) -> String {
        let prefix = source.isEmpty ? "" : "【\(source)】"
        return "\(prefix)排除：\(original)"
    }

    /// 重名时补后缀。正常路径上撞不到——编号按「来源 + 地区」唯一——但订阅名可以随便改，
    /// 有人把两条订阅起成同一个名字时就会撞，而撞了的后果是 Surge 里静默少几个节点。
    private nonisolated static func unique(_ base: String, used: inout Set<String>) -> String {
        var candidate = base
        var attempt = 1
        while used.contains(candidate) {
            attempt += 1
            candidate = "\(base)-\(attempt)"
        }
        used.insert(candidate)
        return candidate
    }
}
