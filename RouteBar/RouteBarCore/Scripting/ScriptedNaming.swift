import Foundation

/// 把 RouteBar 的节点接到 `NodeScript` 上。
///
/// 单独一层是因为两边关心的东西不一样：`NodeScript` 只认一个扁平的 `NodeScriptProxy`
/// 数组，不知道订阅、地区表、端口映射是怎么回事；而调用方手里是 `PortMappedNode`
/// 加一堆订阅记录。翻译放在这里，引擎那边就能用纯数据测。
public enum ScriptedNaming {
    /// 脚本跑出来的东西，外加「跑没跑成」。
    public struct Outcome: Sendable {
        /// 成功时是脚本的规划；失败时是回落用的规范化规划。
        public let plan: NormalizationPlan
        /// 失败原因。为 nil 表示脚本正常跑完。
        public let failure: String?
        public let logs: [String]
        public let warnings: [String]

        public nonisolated var succeeded: Bool { failure == nil }
    }

    /// 按设置里的命名方式算出规划。
    ///
    /// 不是脚本模式、或者脚本是空的，就直接走 `naming` 自己那套，不碰 JS 引擎。
    ///
    /// **脚本失败时回落到规范化输出，而不是抛错。** 这条路径的下游是 Surge 的策略列表：
    /// 抛错意味着 Surge 拿到一份空列表，所有策略组瞬间没有可用节点——为了一个写错的脚本
    /// 把代理整个搞断，代价远大于「名字暂时不是你想要的那套」。失败原因由调用方记进日志
    /// 并显示在界面上，不会悄无声息。
    public nonisolated static func plan(mapped: [PortMappedNode],
                                        subscriptions: [SubscriptionRecord],
                                        settings: RouteBarSettings,
                                        script: String,
                                        naming: NodeNaming,
                                        timeout: TimeInterval = NodeScript.defaultTimeout) -> Outcome {
        let fallback = naming.plan(for: mapped)
        guard settings.nodeNamingStyle == .script else {
            return Outcome(plan: fallback, failure: nil, logs: [], warnings: [])
        }
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Outcome(plan: fallback, failure: "脚本是空的，暂时按「规范化」输出", logs: [], warnings: [])
        }

        do {
            let result = try NodeScript.run(script: script,
                                            proxies: proxies(mapped: mapped,
                                                             subscriptions: subscriptions,
                                                             settings: settings),
                                            timeout: timeout)
            return Outcome(plan: result.plan, failure: nil,
                           logs: result.logs, warnings: result.warnings)
        } catch {
            let reason = (error as? NodeScriptError)?.errorDescription ?? error.localizedDescription
            return Outcome(plan: fallback, failure: reason, logs: [], warnings: [])
        }
    }

    /// 端口映射 + 订阅记录 → 交给脚本的那个数组。
    public nonisolated static func proxies(mapped: [PortMappedNode],
                                           subscriptions: [SubscriptionRecord],
                                           settings: RouteBarSettings) -> [NodeScriptProxy] {
        var nameByID: [UUID: String] = [:]
        var rankByID: [UUID: Int] = [:]
        var updatedByID: [UUID: Date] = [:]
        for (offset, subscription) in subscriptions.enumerated() {
            nameByID[subscription.id] = subscription.name
            rankByID[subscription.id] = offset
            updatedByID[subscription.id] = subscription.updatedAt
        }

        return mapped.map { item in
            // 一个节点可能来自多条订阅（去重后来源是合并的），取列表里靠前的那一条——
            // 和 `NodeNaming` 认主来源的规则保持一致，否则同一个节点在两条路径上
            // 会被算成不同的来源。
            let source = item.node.sourceIDs
                .compactMap { id in rankByID[id].map { (id, $0) } }
                .min { $0.1 < $1.1 }?.0

            return NodeScriptProxy(
                name: item.node.name,
                type: item.node.protocolType.rawValue,
                server: item.node.server,
                port: item.node.serverPort,
                localPort: item.localPort,
                source: source.flatMap { nameByID[$0] } ?? "",
                sourceIndex: source.flatMap { rankByID[$0] } ?? -1,
                sourceUpdatedAt: source.flatMap { updatedByID[$0] },
                // 地区表已经算过一遍了，直接给结果——让脚本自己再写一套关键词匹配
                // 只会多一处要维护、要出错的地方。想自己认的脚本忽略这个字段就好。
                region: NodeNormalization.region(of: item.node.name, rules: settings.regionRules),
                latencyMilliseconds: item.node.latency?.milliseconds)
        }
    }
}


/// 一次脚本试跑的结果，直接喂给网页。
public struct NamingScriptPreview: Sendable {
    public struct Row: Sendable {
        public let name: String
        public let outputName: String
        public let localPort: Int

        public nonisolated init(name: String, outputName: String, localPort: Int) {
            self.name = name
            self.outputName = outputName
            self.localPort = localPort
        }
    }

    /// 脚本输出的行，顺序即 Surge 里的顺序。
    public let rows: [Row]
    /// 交了进去但**没出现在返回值里**的节点。
    ///
    /// 单独列出来而不是只报个数：脚本过滤错了的时候，「少了几个」这个数字说明不了
    /// 任何问题，要看的是「少的是哪几个」——而这恰恰是过滤条件写歪时唯一的线索。
    public let filtered: [Row]
    public let logs: [String]
    public let warnings: [String]
    /// 跑挂了的原因。非 nil 时 `rows` 是空的。
    public let failure: String?
    public let milliseconds: Int
    /// 交给脚本的节点数。`rows.count` 与它不等是正常的——脚本可以增删。
    public let nodeCount: Int

    public nonisolated init(rows: [Row], filtered: [Row] = [], logs: [String], warnings: [String],
                            failure: String?, milliseconds: Int, nodeCount: Int) {
        self.rows = rows
        self.filtered = filtered
        self.logs = logs
        self.warnings = warnings
        self.failure = failure
        self.milliseconds = milliseconds
        self.nodeCount = nodeCount
    }
}
