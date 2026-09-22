import os
import Foundation

/// 一次操作的结果：新的视图状态 + 该记进日志页的消息。
public struct CoordinatorOutcome: Sendable {
    public let state: AppViewState
    public let messages: [OutcomeMessage]

    public nonisolated init(state: AppViewState, messages: [OutcomeMessage] = []) {
        self.state = state
        self.messages = messages
    }
}

/// 订阅协调器：RouteBar 的引擎。
///
/// 串行 actor，独占持有可变的订阅列表与设置，编排完整链路：
/// 拉取 → 解析 → 去重 → 生成 sing-box 配置 → 校验 → 写入 Surge → 重启服务。
///
/// 所有方法都返回 `CoordinatorOutcome`，界面层（`AppModel`）拿到就整份替换自己的状态。
/// 这样界面不持有任何业务可变状态，也就不存在「两个页面各自算了一遍、算出来不一样」的问题。
public actor SubscriptionCoordinator {
    private let stateStore: StateStore
    private let keychain: KeychainStore
    private let fetcher: SubscriptionFetcher
    private let latencyTester: LatencyTester
    private let geoTester: GeoTester

    private var settings: RouteBarSettings
    private var runtime: RuntimeManager
    private var subscriptions: [SubscriptionRecord]
    private var autoUpdatePaused: Bool
    private var serviceState: ServiceState = .stopped
    private var generatedAt: Date?
    /// 首次启动时接管到的既有服务，用于在日志里说明「为什么设置不是默认值」。
    private let adoptedLaunchAgent: DiscoveredLaunchAgent?
    private var regenerationInProgress = false
    private var regenerationWaiters: [CheckedContinuation<Void, Never>] = []
    private var startupMessages: [OutcomeMessage] = []
    private var stateLoadFailure: String?
    private var subscriptionRevisions: [UUID: UUID] = [:]

    public init(stateStore: StateStore = StateStore(),
                keychain: KeychainStore = KeychainStore(),
                fetcher: SubscriptionFetcher = SubscriptionFetcher(),
                latencyTester: LatencyTester = LatencyTester(),
                geoTester: GeoTester = GeoTester()) {
        self.stateStore = stateStore
        self.keychain = keychain
        self.fetcher = fetcher
        self.latencyTester = latencyTester
        self.geoTester = geoTester

        // 从没配置过时，先看机器上有没有现成的 sing-box 服务可以接管。
        // 不这么做的话，已经手搭好一套的用户打开应用只会看到「LaunchAgent 未找到、
        // 服务已停止」——而他的代理明明跑得好好的，只是标识对不上。
        var loadedSettings = RouteBarSettings.defaults()
        var settingsLoaded = false
        var loadMessages: [OutcomeMessage] = []
        do {
            loadedSettings = try stateStore.loadSettings()
            settingsLoaded = true
        } catch {
            loadMessages.append(.init(.error, "设置", "读取设置失败，原文件已保留：\(error.localizedDescription)"))
        }
        var adopted: DiscoveredLaunchAgent?
        if !stateStore.hasStoredSettings,
           let discovered = LaunchAgentDiscovery.discover(plists: stateStore.launchAgentPlists()) {
            loadedSettings = LaunchAgentDiscovery.adopt(discovered, into: loadedSettings)
            adopted = discovered
            do { try stateStore.saveSettings(loadedSettings) }
            catch { loadMessages.append(.init(.error, "设置", "保存接管设置失败：\(error.localizedDescription)")) }
        }
        adoptedLaunchAgent = adopted

        // 把补齐了新字段的设置写回去。
        //
        // 解码时缺失的字段会取默认值，其中 subscriptionToken 是**每次随机生成**的——
        // 不落盘的话订阅地址每次启动都变，用户填进 Surge 的 policy-path 第二天就失效了。
        if settingsLoaded, stateStore.hasStoredSettings {
            do { try stateStore.saveSettings(loadedSettings) }
            catch { loadMessages.append(.init(.error, "设置", "保存设置失败：\(error.localizedDescription)")) }
        }

        var loadedState = RouteBarState()
        var stateReadFailed = false
        do { loadedState = try stateStore.load() }
        catch {
            stateLoadFailure = error.localizedDescription
            stateReadFailed = true
            loadMessages.append(.init(.error, "存储", "读取订阅状态失败，已阻止覆盖原文件：\(error.localizedDescription)"))
        }
        startupMessages = loadMessages
        settings = loadedSettings
        runtime = RuntimeManager(settings: loadedSettings)
        subscriptions = loadedState.subscriptions.map { subscription in
            var subscription = subscription
            subscription.nodes = NodeCatalog.assignEntryIDs(subscription.nodes, sourceID: subscription.id)
            return subscription
        }
        autoUpdatePaused = loadedState.autoUpdatePaused || !settingsLoaded || stateReadFailed
    }

    // MARK: - 快照

    public var paths: RuntimePaths { runtime.paths }

    /// 组装当前视图状态。
    ///
    /// 端口映射在这里现算而不是缓存：它是「启用节点」的纯函数，现算永远和即将写入的
    /// 配置一致；缓存则会在用户刚改完启用状态、还没重新生成时显示过期端口。
    public func snapshot() -> AppViewState {
        // 只要端口映射，不要整份配置：走 generate 会白白多做一次 JSON 序列化，
        // 而快照在每次操作后都要重算。portMapping 内部已经会去重，这里不必先 merge 一遍。
        let mapped = ConfigurationGenerator.portMapping(nodes: subscriptions.filter(\.isEnabled).flatMap(\.nodes))
        return AppViewState(
            subscriptions: subscriptions,
            serviceState: serviceState,
            environment: environmentReport(),
            settings: settings,
            autoUpdatePaused: autoUpdatePaused,
            mappedNodes: mapped,
            generatedAt: generatedAt
        )
    }

    private func environmentReport() -> RouteBarEnvironmentReport {
        RouteBarEnvironmentReport(paths: runtime.paths) {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    private func outcome(_ messages: [OutcomeMessage] = []) -> CoordinatorOutcome {
        CoordinatorOutcome(state: snapshot(), messages: messages)
    }

    // MARK: - 启动

    /// 首次启动流程：探测既有配置、刷新服务状态。
    public func bootstrap() async -> CoordinatorOutcome {
        var messages = startupMessages
        startupMessages.removeAll()
        if let adopted = adoptedLaunchAgent {
            messages.append(.init(.notice, "环境",
                                  "已接管现有的 sing-box 服务「\(adopted.label)」，配置与日志路径取自它的 LaunchAgent"))
        }
        serviceState = await runtime.status()
        if subscriptions.isEmpty, stateLoadFailure == nil {
            do {
                if let imported = try importExistingSubscription() {
                    messages.append(.init(.notice, "订阅", "从现有 Mihomo 配置导入了订阅「\(imported)」"))
                }
            } catch {
                messages.append(.init(.error, "订阅", "从 Mihomo 导入订阅失败：\(error.localizedDescription)"))
            }
        }
        messages.append(.init(.info, "生命周期",
                              "引擎已就绪：\(subscriptions.count) 个订阅 · sing-box \(serviceState.label)"))
        return outcome(messages)
    }

    /// 从既有 Mihomo 配置里捞一条订阅地址，免去首次使用时手工粘贴。
    private func importExistingSubscription() throws -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/mihomo/config.yaml")
        guard let text = try? String(contentsOf: path, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #"url:\s*\"([^\"]+)\""#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let name = "当前订阅"
        try saveSubscription(id: nil, name: name, url: String(text[range]),
                             note: "从现有 Mihomo 配置导入", interval: 6)
        return name
    }

    // MARK: - 订阅增删改

    public func subscriptionURL(for id: UUID) throws -> String { try keychain.value(for: id) ?? "" }

    /// `nodeNameTemplate` 传 nil 表示「这次不动它」，传空串表示「清掉，跟随全局」。
    /// 两者必须分开：调用方（网页表单、命令行）不一定每次都带上这个字段。
    @discardableResult
    public func saveSubscription(id: UUID?, name: String, url: String, note: String, interval: Int,
                                 nodeNameTemplate: String? = nil) throws -> UUID {
        let recordID = id ?? UUID()
        try ensureStateWritable()
        try keychain.set(url, for: recordID)
        let previous = subscriptions
        let normalizedTemplate = nodeNameTemplate.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let index = subscriptions.firstIndex(where: { $0.id == recordID }) {
            subscriptions[index].name = name
            subscriptions[index].note = note
            subscriptions[index].updateIntervalHours = interval
            if let normalizedTemplate {
                subscriptions[index].nodeNameTemplate = normalizedTemplate.isEmpty ? nil : normalizedTemplate
            }
        } else {
            subscriptions.append(SubscriptionRecord(
                id: recordID, name: name, note: note, updateIntervalHours: interval,
                nodeNameTemplate: (normalizedTemplate?.isEmpty ?? true) ? nil : normalizedTemplate))
        }
        do { try persist() }
        catch { subscriptions = previous; throw error }
        subscriptionRevisions[recordID] = UUID()
        return recordID
    }

    public func delete(_ id: UUID) -> CoordinatorOutcome {
        let name = subscriptions.first { $0.id == id }?.name ?? "未知订阅"
        let previous = subscriptions
        do {
            try ensureStateWritable()
            subscriptions.removeAll { $0.id == id }
            try persist()
        } catch {
            subscriptions = previous
            return outcome([.init(.error, "订阅", "删除订阅失败：\(error.localizedDescription)")])
        }
        subscriptionRevisions.removeValue(forKey: id)
        do { try keychain.remove(id) }
        catch {
            return outcome([.init(.error, "订阅", "订阅已删除，但钥匙串条目清理失败：\(error.localizedDescription)")])
        }
        return outcome([.init(.notice, "订阅", "已删除订阅「\(name)」")])
    }

    public func setSubscriptionEnabled(_ enabled: Bool, for id: UUID) async -> CoordinatorOutcome {
        guard let index = subscriptions.firstIndex(where: { $0.id == id }) else { return outcome() }
        let previous = subscriptions
        subscriptions[index].isEnabled = enabled
        subscriptions[index].status = enabled ? .idle : .disabled
        let name = subscriptions[index].name
        do { try persist() }
        catch {
            subscriptions = previous
            return outcome([.init(.error, "存储", "保存订阅状态失败：\(error.localizedDescription)")])
        }
        return outcome([.init(.notice, "订阅", "\(enabled ? "启用" : "停用")订阅「\(name)」")])
    }

    public func setNodeEnabled(_ enabled: Bool, id: String) -> CoordinatorOutcome {
        let previous = subscriptions
        var name = id
        for subscriptionIndex in subscriptions.indices {
            for nodeIndex in subscriptions[subscriptionIndex].nodes.indices
            where subscriptions[subscriptionIndex].nodes[nodeIndex].entryID == id {
                subscriptions[subscriptionIndex].nodes[nodeIndex].isEnabled = enabled
                name = subscriptions[subscriptionIndex].nodes[nodeIndex].name
                do { try persist() }
                catch {
                    subscriptions = previous
                    return outcome([.init(.error, "存储", "保存节点状态失败：\(error.localizedDescription)")])
                }
                return outcome([.init(.info, "节点", "\(enabled ? "启用" : "停用")节点「\(name)」")])
            }
        }
        return outcome([.init(.warning, "节点", "没有找到节点条目「\(name)」")])
    }

    // MARK: - 更新

    public func dueSubscriptionIDs() -> [UUID] {
        subscriptions.filter { UpdateSchedule.isDue($0, isPaused: autoUpdatePaused) }.map(\.id)
    }

    public func enabledSubscriptionIDs() -> [UUID] {
        subscriptions.filter(\.isEnabled).map(\.id)
    }

    /// 把某条订阅标记为「更新中」，让界面立刻有反馈而不必等网络往返。
    public func markUpdating(_ id: UUID) -> CoordinatorOutcome {
        if let index = subscriptions.firstIndex(where: { $0.id == id }) {
            subscriptions[index].status = .updating
        }
        return outcome()
    }

    public func update(_ id: UUID) async -> CoordinatorOutcome {
        guard let index = subscriptions.firstIndex(where: { $0.id == id }) else { return outcome() }
        let name = subscriptions[index].name
        let revision = subscriptionRevisions[id]
        // 尝试时刻在动手之前就记下，两条失败路径（地址缺失、拉取出错）共用一个起算点。
        subscriptions[index].lastAttemptAt = .now
        subscriptions[index].status = .updating
        do {
            guard let value = try keychain.value(for: id), let url = URL(string: value) else {
                return outcome(recordFailure(id, name: name, reason: "订阅地址缺失或无效",
                                             message: "更新失败：「\(name)」订阅地址缺失或无效"))
            }
            let data = try await fetcher.fetch(url)
            guard subscriptionRevisions[id] == revision else {
                return outcome([.init(.info, "订阅", "「\(name)」已修改，忽略旧请求结果")])
            }
            let parsed = try SubscriptionParser.parseSubscription(data, sourceID: id)
            guard !parsed.isEmpty else { throw SubscriptionError.empty }
            // 重新定位：await 期间列表可能已被增删。
            guard let current = subscriptions.firstIndex(where: { $0.id == id }) else { return outcome() }
            subscriptions[current].nodes = NodeCatalog.carryPersistedState(from: subscriptions[current].nodes, to: parsed)
            subscriptions[current].updatedAt = .now
            subscriptions[current].status = .success
            subscriptions[current].lastError = nil
            // 成功一次就把退避清零，下一次故障从最短的那一档重新开始。
            subscriptions[current].consecutiveFailures = 0
            try persist()
            let protocolSummary = ProxyProtocol.allCases.compactMap { type in
                let count = parsed.count { $0.protocolType == type }
                return count > 0 ? "\(type.label) \(count)" : nil
            }.joined(separator: " · ")
            return outcome([.init(.notice, "订阅", "「\(name)」更新成功，解析到 \(parsed.count) 个节点（\(protocolSummary)）")])
        } catch {
            guard subscriptionRevisions[id] == revision else { return outcome() }
            return outcome(recordFailure(id, name: name, reason: error.localizedDescription,
                                         message: "「\(name)」更新失败：\(error.localizedDescription)"))
        }
    }

    /// 记一次失败：置状态、累加退避计数，并在日志里说明下次自动重试是什么时候。
    ///
    /// 「什么时候会再试」必须写出来。退避之后失败订阅不再每半分钟刷一行，用户看到的是
    /// 一条孤零零的错误——不说明的话，那看着像是 RouteBar 从此不管这条订阅了。
    ///
    /// 订阅在 await 期间被删掉时返回空：那条记录已经不存在了，为它报一次失败只会让
    /// 用户去找一个列表里没有的东西。
    private func recordFailure(_ id: UUID, name: String, reason: String, message: String) -> [OutcomeMessage] {
        guard let index = subscriptions.firstIndex(where: { $0.id == id }) else { return [] }
        subscriptions[index].status = .failed
        subscriptions[index].lastError = reason
        subscriptions[index].consecutiveFailures += 1
        var storageMessages: [OutcomeMessage] = []
        do { try persist() }
        catch { storageMessages.append(.init(.error, "存储", "保存失败状态失败：\(error.localizedDescription)")) }
        let minutes = Int(UpdateSchedule.retryDelay(afterFailures: subscriptions[index].consecutiveFailures) / 60)
        return storageMessages + [.init(.error, "订阅", "\(message)；\(minutes) 分钟后自动重试（现在也可以手动更新）")]
    }

    // MARK: - 生成与安装

    public func regenerate(forceRestart: Bool = false) async -> CoordinatorOutcome {
        outcome(await regenerateMessages(forceRestart: forceRestart))
    }

    // MARK: - 命名脚本

    public func namingScript() -> String {
        (try? stateStore.loadNamingScript()) ?? ""
    }

    /// 存脚本并立刻重新生成一次——命名是即时生效的，存完不重算等于要用户
    /// 再手动点一次「重新生成」才看得到结果。
    public func saveNamingScript(_ script: String) async -> CoordinatorOutcome {
        do {
            try stateStore.saveNamingScript(script)
        } catch {
            return outcome([.init(.error, "脚本", "保存失败：\(error.localizedDescription)")])
        }
        return await regenerate()
    }

    /// 试跑：按传进来的脚本算一遍，**不保存、不安装**。
    ///
    /// 用当前这批真实节点跑，而不是造几个假的——脚本要处理的恰恰是机场那些花名和
    /// 混在里面的订阅信息节点，假数据试不出问题。
    public func previewNamingScript(_ script: String) -> NamingScriptPreview {
        let active = subscriptions.filter(\.isEnabled).flatMap(\.nodes)
        let mapped = ConfigurationGenerator.portMapping(nodes: active)
        let proxies = ScriptedNaming.proxies(mapped: mapped, subscriptions: subscriptions, settings: settings)
        do {
            let result = try NodeScript.run(script: script, proxies: proxies)
            let rows = result.plan.lines.map { line in
                NamingScriptPreview.Row(name: proxies[line.index].name,
                                        outputName: line.name,
                                        localPort: proxies[line.index].localPort)
            }
            // 被过滤的按**输入顺序**列，不按输出顺序——它们压根没进输出，
            // 而输入顺序就是端口顺序，对着节点页能一眼找到是哪几个。
            let emitted = Set(result.plan.lines.map(\.index))
            let filtered = proxies.indices.filter { !emitted.contains($0) }.map {
                NamingScriptPreview.Row(name: proxies[$0].name, outputName: "",
                                        localPort: proxies[$0].localPort)
            }
            return NamingScriptPreview(rows: rows, filtered: filtered,
                                       logs: result.logs, warnings: result.warnings,
                                       failure: nil, milliseconds: Int(result.duration * 1000),
                                       nodeCount: proxies.count, keptCount: emitted.count)
        } catch {
            let reason = (error as? NodeScriptError)?.errorDescription ?? error.localizedDescription
            return NamingScriptPreview(rows: [], logs: [], warnings: [], failure: reason,
                                       milliseconds: 0, nodeCount: proxies.count)
        }
    }

    /// Surge 拉取的裸策略列表。
    ///
    /// 放在协调器而不是 `AppModel`：脚本模式要读磁盘上的脚本，而那是 `stateStore` 的事。
    public func policyList() -> String {
        let active = subscriptions.filter(\.isEnabled).flatMap(\.nodes)
        let mapped = ConfigurationGenerator.portMapping(nodes: active)
        let naming = NodeNaming(settings: settings, subscriptions: subscriptions)
        return ConfigurationGenerator.surgePolicyLines(
            mapped, naming: naming, plan: namingPlan(for: active, naming: naming).plan)
    }

    /// 生成 → 校验 → 安装 → 重启，并把每一步的结果转成日志消息。
    private func regenerateMessages(forceRestart: Bool) async -> [OutcomeMessage] {
        // CommandRunner 是 async 的，等待子进程时 actor 会允许其他调用进入。安装链路本身仍必须
        // 严格串行，否则旧配置的 check 后完成时可能反过来覆盖较新的配置。
        await acquireRegenerationSlot()
        defer { releaseRegenerationSlot() }

        // 排队等锁期间调用方可能已经取消（防抖被后一次改动取代）。
        // `withCheckedContinuation` 不响应取消，只能在拿到锁之后自己检查一次，
        // 否则被取代的那次重装仍会跑完——虽然无害，但会多一次无谓的校验和落盘。
        if Task.isCancelled {
            return [.init(.info, "配置", "重新生成已被更新的改动取代，本次跳过")]
        }

        let active = subscriptions.filter(\.isEnabled).flatMap(\.nodes)
        let naming = NodeNaming(settings: settings, subscriptions: subscriptions)
        let scripted = namingPlan(for: active, naming: naming)
        // 脚本失败只是名字不对，配置本身照样装——所以把这条消息拼在结果前面，
        // 而不是直接 return 掉。用户在日志页看到它，同时代理继续可用。
        let prefix: [OutcomeMessage] = scripted.failure.map {
            [.init(.error, "脚本", "\($0)。本次按「规范化」输出")]
        } ?? []

        do {
            let generated = try ConfigurationGenerator.generate(
                nodes: active, naming: naming, plan: scripted.plan)
            guard !generated.nodes.isEmpty else {
                serviceState = await runtime.stop()
                if let reason = serviceState.failureReason {
                    return prefix + [.init(.error, "服务", "没有启用节点，但停止旧出口失败：\(reason)")]
                }
                // 登录时 LaunchAgent 可能再次加载，磁盘配置也必须撤销旧出口。
                if FileManager.default.fileExists(atPath: runtime.paths.singBoxConfig.path) {
                    try await runtime.install(generated)
                }
                try stateStore.saveGenerated(generated)
                generatedAt = .now
                return prefix + [.init(.notice, "配置", "没有启用节点，已停止 sing-box 并清空客户端出口")]
            }
            // 只有 sing-box 那一份变了才值得重启：只改节点名时那份 JSON 一个字节都没动
            // （名字只出现在给客户端的策略列表里），顺手重启等于白断一次全部连接。
            let singBoxUnchanged = runtime.installedSingBoxConfigMatches(generated)
            if singBoxUnchanged, !forceRestart {
                try stateStore.saveGenerated(generated)
                generatedAt = .now
                // 不重装也要把服务状态对齐：跳过分支是「什么都不做」，但期间 sing-box
                // 可能已经被外部停掉或崩了，直接 return 会让界面一直显示旧状态，
                // 直到下次窗口激活才自我纠正。
                serviceState = await runtime.status()
                return prefix + [.init(.info, "配置", "配置未变化，已跳过安装与 sing-box 重启")]
            }
            try await runtime.install(generated)
            try stateStore.saveGenerated(generated)
            generatedAt = .now
            var messages: [OutcomeMessage] = [
                .init(.notice, "配置", "已生成并安装 \(generated.nodes.count) 个节点出口"),
            ]
            guard forceRestart || !singBoxUnchanged else {
                serviceState = await runtime.status()
                messages.append(.init(.info, "服务", "sing-box 配置未变，无需重启"))
                return prefix + messages
            }
            serviceState = await runtime.restart()
            switch serviceState {
            case .running:
                messages.append(.init(.info, "服务", "sing-box 已重启"))
            case .stopped:
                messages.append(.init(.warning, "服务", "sing-box 未在运行，请检查 LaunchAgent"))
            case .failed(let reason):
                messages.append(.init(.error, "服务", "sing-box 重启失败：\(reason)"))
            }
            return prefix + messages
        } catch {
            CoreLog.configuration.error("生成失败：\(error.localizedDescription, privacy: .public)")
            return prefix + [.init(.error, "配置", "配置生成失败：\(error.localizedDescription)")]
        }
    }

    /// 按当前命名方式算出这一批节点的规划。
    ///
    /// 脚本模式要读磁盘上的脚本并跑 JS，所以不能放进 `NodeNaming`（那是纯计算的 Domain 层）。
    /// 读不到脚本时交空串——`ScriptedNaming` 会当作「没配」回落到规范化，而不是报一个
    /// 用户看不懂的文件错误。
    private func namingPlan(for nodes: [ProxyNode], naming: NodeNaming) -> ScriptedNaming.Outcome {
        ScriptedNaming.plan(mapped: ConfigurationGenerator.portMapping(nodes: nodes),
                            subscriptions: subscriptions,
                            settings: settings,
                            script: (try? stateStore.loadNamingScript()) ?? "",
                            naming: naming)
    }

    private func acquireRegenerationSlot() async {
        guard regenerationInProgress else {
            regenerationInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            regenerationWaiters.append(continuation)
        }
    }

    private func releaseRegenerationSlot() {
        if regenerationWaiters.isEmpty {
            regenerationInProgress = false
        } else {
            regenerationWaiters.removeFirst().resume()
        }
    }

    // MARK: - 延迟测试

    public func mappedNodes() -> [PortMappedNode] {
        ConfigurationGenerator.portMapping(nodes: subscriptions.filter(\.isEnabled).flatMap(\.nodes))
    }

    /// 测试一批节点。测速端点与采样次数由调用方（设置）给出，不在引擎里写死。
    public func testNodes(_ mapped: [PortMappedNode],
                          testURL: URL,
                          samples: Int) async -> CoordinatorOutcome {
        guard !mapped.isEmpty else { return outcome() }
        var tester = latencyTester
        tester.testURL = testURL
        tester.samples = samples
        let results = await tester.test(mapped)
        return applyLatency(results, endpoint: testURL)
    }

    private func applyLatency(_ results: [String: LatencyRecord], endpoint: URL) -> CoordinatorOutcome {
        for subscriptionIndex in subscriptions.indices {
            for nodeIndex in subscriptions[subscriptionIndex].nodes.indices {
                let id = subscriptions[subscriptionIndex].nodes[nodeIndex].entryID
                if let latency = results[id] {
                    subscriptions[subscriptionIndex].nodes[nodeIndex].latency = latency
                }
            }
        }
        do { try persist() }
        catch { return outcome([.init(.error, "存储", "测速结果保存失败：\(error.localizedDescription)")]) }
        let succeeded = results.values.filter { $0.outcome == .success }.count
        // 记下用了哪个端点：换端点后数字会整体平移，日志里没有这一条就无从解释。
        let host = endpoint.host ?? endpoint.absoluteString
        return outcome([.init(.info, "测速",
                              "完成 \(results.count) 个节点（经 \(host)）：\(succeeded) 可用 · \(results.count - succeeded) 失败")])
    }

    // MARK: - 落地探测

    /// 探测一批节点的真实落地地区，结果落盘。
    ///
    /// 与测速分开而不是合成一次请求：测速要的是「这条链路有多快」，会连测多次取最好的；
    /// 落地要的是「出口在哪」，测一次就够，而且换的是另一个对端。合在一起的话，
    /// 想只刷新延迟的人会被迫连着把 86 个节点的落地也重探一遍。
    public func probeGeo(_ mapped: [PortMappedNode]) async -> CoordinatorOutcome {
        guard !mapped.isEmpty else { return outcome() }
        let results = await geoTester.probe(mapped)
        for subscriptionIndex in subscriptions.indices {
            for nodeIndex in subscriptions[subscriptionIndex].nodes.indices {
                let id = subscriptions[subscriptionIndex].nodes[nodeIndex].entryID
                if let record = results[id] {
                    subscriptions[subscriptionIndex].nodes[nodeIndex].geo = record
                }
            }
        }
        do { try persist() }
        catch { return outcome([.init(.error, "存储", "落地探测结果保存失败：\(error.localizedDescription)")]) }

        let succeeded = results.values.filter { $0.outcome == .success }.count
        // 把落地与节点名不一致的那些点出来——这正是做这个功能的原因，
        // 只报「成功 N 个」的话，用户还得自己逐行去比。
        let mismatched = mismatchCount(results)
        var text = "完成 \(results.count) 个节点的落地探测：\(succeeded) 个有出口 IP · \(results.count - succeeded) 个失败"
        if mismatched > 0 {
            text += "；其中 \(mismatched) 个的落地地区与节点名不符"
        }
        return outcome([.init(.info, "落地", text)])
    }

    /// 落地国家与节点名里写的地区对不上的个数。
    ///
    /// 只做一件很轻的事：拿地区的中英文名和国家码去节点名里找。机场的命名五花八门
    /// （「新加坡」「狮城」「SG」「Singapore」都有），所以这只是个提示性的计数，
    /// 不作为判据去改动任何数据——真要认哪个节点不对，界面上两个字段并排摆着更可靠。
    private func mismatchCount(_ results: [String: GeoRecord]) -> Int {
        let names = Dictionary(
            subscriptions.flatMap(\.nodes).map { ($0.entryID, $0.name) },
            uniquingKeysWith: { first, _ in first })
        return results.reduce(into: 0) { total, entry in
            let (id, record) = entry
            guard record.outcome == .success, !record.countryCode.isEmpty,
                  let name = names[id] else { return }
            let candidates = [
                record.countryCode,
                record.regionName(locale: Locale(identifier: "zh_CN")),
                record.regionName(locale: Locale(identifier: "en_US")),
            ].filter { !$0.isEmpty }
            let matched = candidates.contains { name.localizedCaseInsensitiveContains($0) }
            if !matched { total += 1 }
        }
    }

    /// 对指定目标逐节点测一次可达性，**结果不落盘、不写进节点**。
    ///
    /// 这一点是有意的：节点自己的 `latency` 字段代表的是「用当前测速端点量出来的基准延迟」，
    /// 各处界面都按它排序和着色。网络测试页测的是用户临时填的某个目标（可能是一个必然
    /// 超时的站点），把那个结果写进去会把整份基准数据污染掉，而用户根本不会预期
    /// 「我测了一下 GitHub，节点列表里的延迟就全变了」。
    public func probeTargets(_ mapped: [PortMappedNode], url: URL) async -> [String: LatencyRecord] {
        guard !mapped.isEmpty else { return [:] }
        var tester = latencyTester
        tester.testURL = url
        // 只测一次：这一页问的是「通不通、大概多久」，不是「最快能到多少」。
        // 连测三次会把一页几十个节点的等待时间翻三倍。
        tester.samples = 1
        return await tester.test(mapped)
    }

    // MARK: - 服务控制

    public func refreshServiceState() async -> CoordinatorOutcome {
        let previous = serviceState
        serviceState = await runtime.status()
        guard previous != serviceState else { return outcome() }
        return outcome([.init(serviceState.failureReason == nil ? .info : .error, "服务",
                              "sing-box 状态变为「\(serviceState.label)」")])
    }

    public func restartService() async -> CoordinatorOutcome {
        serviceState = await runtime.restart()
        return outcome([.init(serviceState.isRunning ? .notice : .error, "服务",
                              serviceState.isRunning ? "sing-box 已启动" : "sing-box 启动失败：\(serviceState.failureReason ?? "未知原因")")])
    }

    public func stopService() async -> CoordinatorOutcome {
        serviceState = await runtime.stop()
        if let reason = serviceState.failureReason {
            return outcome([.init(.error, "服务", "停止 sing-box 失败：\(reason)")])
        }
        return outcome([.init(.notice, "服务", "已停止 sing-box")])
    }

    public func logTails() -> (standard: String, error: String) {
        (runtime.tail(runtime.paths.singBoxLog), runtime.tail(runtime.paths.singBoxErrorLog))
    }

    /// sing-box 自上次以来新写的日志。
    ///
    /// 只读 stderr 那一份：sing-box 把**所有**级别都写进 stderr，stdout 那个文件
    /// 从头到尾是空的（真机上验证过，0 字节）。两份都读只会把同一批行读两遍。
    public func newSingBoxLog(since offset: UInt64) -> (text: String, offset: UInt64) {
        runtime.readNewLines(of: runtime.paths.singBoxErrorLog, from: offset)
    }

    private let logArchive = LogArchiveStore()
    private var lastPrune: Date?

    /// 把新读到的行按日期归档，并顺手清掉过期的。
    ///
    /// 归档的是**全部**行，不像内存缓冲那样只留 warning 以上：缓冲是「现在要注意
    /// 什么」，归档是「那天到底发生了什么」，后者被过滤过就失去了回溯的意义。
    @discardableResult
    public func archiveSingBoxLog(_ lines: [SingBoxLogLine]) -> Bool {
        do {
            try logArchive.append(lines)
        } catch {
            CoreLog.configuration.error("归档日志失败：\(error.localizedDescription, privacy: .public)")
            return false
        }
        pruneIfDue()
        return true
    }

    /// 清理最多一小时来一次。
    ///
    /// RouteBar 自己的每一条记录都会走到这里（一次订阅更新就是几十条），而清理要
    /// 列一遍目录。按次清理等于把一个每小时做一次就够的活儿做上几百遍。
    private func pruneIfDue(now: Date = .now) {
        if let lastPrune, now.timeIntervalSince(lastPrune) < 3600 { return }
        lastPrune = now
        logArchive.prune(now: now)
    }

    public func archivedLogDates() -> [Date] { logArchive.availableDates() }

    public func archivedLog(_ date: Date) -> [SingBoxLogLine] { logArchive.read(date) }

    public func archivedLogSize() -> Int64 { logArchive.totalSize() }

    public func archivedLogDirectory() -> URL { logArchive.directory }

    public func ingestOffset() -> UInt64 { logArchive.loadIngestOffset() }

    public func saveIngestOffset(_ offset: UInt64) { logArchive.saveIngestOffset(offset) }

    public func deleteArchivedLog(_ day: Date) -> CoordinatorOutcome {
        let removed = logArchive.delete(day)
        return outcome([.init(removed ? .notice : .warning, "日志",
                              removed ? "已删除该日归档" : "该日没有归档文件可删")])
    }

    public func clearSingBoxLogs() -> CoordinatorOutcome {
        do {
            try runtime.clearLogs()
            return outcome([.init(.notice, "日志", "已清空 sing-box 日志文件")])
        } catch {
            return outcome([.init(.error, "日志", "清空 sing-box 日志失败：\(error.localizedDescription)")])
        }
    }

    // MARK: - 设置

    public func saveSettings(_ newSettings: RouteBarSettings) async -> CoordinatorOutcome {
        let namingChanged = newSettings.nodeNameTemplate != settings.nodeNameTemplate
        do {
            try stateStore.saveSettings(newSettings)
            settings = newSettings
            runtime = RuntimeManager(settings: newSettings)
            serviceState = await runtime.status()
            var messages: [OutcomeMessage] = [
                .init(.notice, "设置", namingChanged ? "节点命名规则已更新" : "环境路径已更新"),
            ]
            // 命名只影响 Surge 那一侧，改完不重装的话，配置文件里还是旧名字，
            // 而界面已经显示新规则了——要等下一次订阅更新才对得上。
            if namingChanged {
                messages += await regenerateMessages(forceRestart: false)
            }
            return outcome(messages)
        } catch {
            return outcome([.init(.error, "设置", "保存设置失败：\(error.localizedDescription)")])
        }
    }

    // MARK: - LaunchAgent

    public func launchAgentState() -> LaunchAgentState { runtime.launchAgentState() }

    public func launchAgentPreview() -> String {
        (try? runtime.launchAgentPreview()) ?? "无法生成预览"
    }

    public func installLaunchAgent(allowOverwritingForeignFile: Bool) async -> CoordinatorOutcome {
        do {
            try await runtime.installLaunchAgent(allowOverwritingForeignFile: allowOverwritingForeignFile)
            serviceState = await runtime.status()
            return outcome([.init(.notice, "服务", "已安装并加载 LaunchAgent（\(settings.launchAgentLabel)）")])
        } catch {
            return outcome([.init(.error, "服务", "安装 LaunchAgent 失败：\(error.localizedDescription)")])
        }
    }

    public func createRequiredDirectories() -> CoordinatorOutcome {
        do {
            try runtime.createRequiredDirectories()
            return outcome([.init(.notice, "设置", "已创建缺失目录")])
        } catch {
            return outcome([.init(.error, "设置", "创建目录失败：\(error.localizedDescription)")])
        }
    }

    public func setAutoUpdatePaused(_ paused: Bool) -> CoordinatorOutcome {
        let previous = autoUpdatePaused
        autoUpdatePaused = paused
        do { try persist() }
        catch {
            autoUpdatePaused = previous
            return outcome([.init(.error, "存储", "保存自动更新状态失败：\(error.localizedDescription)")])
        }
        return outcome([.init(.notice, "更新", paused ? "已暂停自动更新" : "已恢复自动更新")])
    }

    // MARK: - 落盘

    private func persist() throws {
        try ensureStateWritable()
        try stateStore.save(RouteBarState(subscriptions: subscriptions, autoUpdatePaused: autoUpdatePaused))
    }

    private func ensureStateWritable() throws {
        if let stateLoadFailure {
            throw NSError(domain: "RouteBar.Storage", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "原订阅状态无法读取，已阻止覆盖。请先恢复原文件再重启：\(stateLoadFailure)"])
        }
    }

    enum SubscriptionError: LocalizedError {
        case empty
        var errorDescription: String? { "订阅中没有可用的 VLESS、SS、Trojan、VMess 或 Hysteria2 节点" }
    }
}
