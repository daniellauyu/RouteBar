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

    public init(stateStore: StateStore = StateStore(),
                keychain: KeychainStore = KeychainStore(),
                fetcher: SubscriptionFetcher = SubscriptionFetcher(),
                latencyTester: LatencyTester = LatencyTester()) {
        self.stateStore = stateStore
        self.keychain = keychain
        self.fetcher = fetcher
        self.latencyTester = latencyTester

        // 从没配置过时，先看机器上有没有现成的 sing-box 服务可以接管。
        // 不这么做的话，已经手搭好一套的用户打开应用只会看到「LaunchAgent 未找到、
        // 服务已停止」——而他的代理明明跑得好好的，只是标识对不上。
        var loadedSettings = stateStore.loadSettings()
        var adopted: DiscoveredLaunchAgent?
        if !stateStore.hasStoredSettings,
           let discovered = LaunchAgentDiscovery.discover(plists: stateStore.launchAgentPlists()) {
            loadedSettings = LaunchAgentDiscovery.adopt(discovered, into: loadedSettings)
            adopted = discovered
            try? stateStore.saveSettings(loadedSettings)
        }
        adoptedLaunchAgent = adopted

        // 把补齐了新字段的设置写回去。
        //
        // 解码时缺失的字段会取默认值，其中 subscriptionToken 是**每次随机生成**的——
        // 不落盘的话订阅地址每次启动都变，用户填进 Surge 的 policy-path 第二天就失效了。
        if stateStore.hasStoredSettings {
            try? stateStore.saveSettings(loadedSettings)
        }

        let loadedState = stateStore.load()
        settings = loadedSettings
        runtime = RuntimeManager(settings: loadedSettings)
        subscriptions = loadedState.subscriptions.map { subscription in
            var subscription = subscription
            subscription.nodes = NodeCatalog.assignEntryIDs(subscription.nodes, sourceID: subscription.id)
            return subscription
        }
        autoUpdatePaused = loadedState.autoUpdatePaused
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
        var messages: [OutcomeMessage] = []
        if let adopted = adoptedLaunchAgent {
            messages.append(.init(.notice, "环境",
                                  "已接管现有的 sing-box 服务「\(adopted.label)」，配置与日志路径取自它的 LaunchAgent"))
        }
        serviceState = await runtime.status()
        if subscriptions.isEmpty {
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

    public func subscriptionURL(for id: UUID) -> String { keychain.value(for: id) ?? "" }

    /// `nodeNameTemplate` 传 nil 表示「这次不动它」，传空串表示「清掉，跟随全局」。
    /// 两者必须分开：调用方（网页表单、命令行）不一定每次都带上这个字段。
    @discardableResult
    public func saveSubscription(id: UUID?, name: String, url: String, note: String, interval: Int,
                                 nodeNameTemplate: String? = nil) throws -> UUID {
        let recordID = id ?? UUID()
        try keychain.set(url, for: recordID)
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
        try? persist()
        return recordID
    }

    public func delete(_ id: UUID) -> CoordinatorOutcome {
        let name = subscriptions.first { $0.id == id }?.name ?? "未知订阅"
        keychain.remove(id)
        subscriptions.removeAll { $0.id == id }
        try? persist()
        return outcome([.init(.notice, "订阅", "已删除订阅「\(name)」")])
    }

    public func setSubscriptionEnabled(_ enabled: Bool, for id: UUID) async -> CoordinatorOutcome {
        guard let index = subscriptions.firstIndex(where: { $0.id == id }) else { return outcome() }
        subscriptions[index].isEnabled = enabled
        subscriptions[index].status = enabled ? .idle : .disabled
        let name = subscriptions[index].name
        try? persist()
        return outcome([.init(.notice, "订阅", "\(enabled ? "启用" : "停用")订阅「\(name)」")])
    }

    public func setNodeEnabled(_ enabled: Bool, id: String) -> CoordinatorOutcome {
        var name = id
        for subscriptionIndex in subscriptions.indices {
            for nodeIndex in subscriptions[subscriptionIndex].nodes.indices
            where subscriptions[subscriptionIndex].nodes[nodeIndex].entryID == id {
                subscriptions[subscriptionIndex].nodes[nodeIndex].isEnabled = enabled
                name = subscriptions[subscriptionIndex].nodes[nodeIndex].name
                try? persist()
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
        guard let value = keychain.value(for: id), let url = URL(string: value) else {
            subscriptions[index].status = .failed
            subscriptions[index].lastError = "订阅地址缺失或无效"
            try? persist()
            return outcome([.init(.error, "订阅", "更新失败：「\(name)」订阅地址缺失或无效")])
        }

        subscriptions[index].status = .updating
        do {
            let data = try await fetcher.fetch(url)
            let parsed = try SubscriptionParser.parseSubscription(data, sourceID: id)
            guard !parsed.isEmpty else { throw SubscriptionError.empty }
            // 重新定位：await 期间列表可能已被增删。
            guard let current = subscriptions.firstIndex(where: { $0.id == id }) else { return outcome() }
            subscriptions[current].nodes = NodeCatalog.carryPersistedState(from: subscriptions[current].nodes, to: parsed)
            subscriptions[current].updatedAt = .now
            subscriptions[current].status = .success
            subscriptions[current].lastError = nil
            try? persist()
            let protocolSummary = ProxyProtocol.allCases.compactMap { type in
                let count = parsed.count { $0.protocolType == type }
                return count > 0 ? "\(type.label) \(count)" : nil
            }.joined(separator: " · ")
            return outcome([.init(.notice, "订阅", "「\(name)」更新成功，解析到 \(parsed.count) 个节点（\(protocolSummary)）")])
        } catch {
            guard let current = subscriptions.firstIndex(where: { $0.id == id }) else { return outcome() }
            subscriptions[current].status = .failed
            subscriptions[current].lastError = error.localizedDescription
            try? persist()
            return outcome([.init(.error, "订阅", "「\(name)」更新失败：\(error.localizedDescription)")])
        }
    }

    // MARK: - 生成与安装

    public func regenerate(forceRestart: Bool = false) async -> CoordinatorOutcome {
        outcome(await regenerateMessages(forceRestart: forceRestart))
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

        let merged = NodeCatalog.merge(subscriptions.filter(\.isEnabled).flatMap(\.nodes))
        do {
            let generated = try ConfigurationGenerator.generate(
                nodes: merged, naming: NodeNaming(settings: settings, subscriptions: subscriptions))
            guard !generated.nodes.isEmpty else {
                return [.init(.warning, "配置", "没有启用节点，已跳过生成")]
            }
            try stateStore.saveGenerated(generated)
            generatedAt = .now
            // 只有 sing-box 那一份变了才值得重启：只改节点名时那份 JSON 一个字节都没动
            // （名字只出现在给客户端的策略列表里），顺手重启等于白断一次全部连接。
            let singBoxUnchanged = runtime.installedSingBoxConfigMatches(generated)
            if singBoxUnchanged, !forceRestart {
                // 不重装也要把服务状态对齐：跳过分支是「什么都不做」，但期间 sing-box
                // 可能已经被外部停掉或崩了，直接 return 会让界面一直显示旧状态，
                // 直到下次窗口激活才自我纠正。
                serviceState = await runtime.status()
                return [.init(.info, "配置", "配置未变化，已跳过安装与 sing-box 重启")]
            }
            try await runtime.install(generated)
            var messages: [OutcomeMessage] = [
                .init(.notice, "配置", "已生成并安装 \(generated.nodes.count) 个节点出口"),
            ]
            guard forceRestart || !singBoxUnchanged else {
                serviceState = await runtime.status()
                messages.append(.init(.info, "服务", "sing-box 配置未变，无需重启"))
                return messages
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
            return messages
        } catch {
            CoreLog.configuration.error("生成失败：\(error.localizedDescription, privacy: .public)")
            return [.init(.error, "配置", "配置生成失败：\(error.localizedDescription)")]
        }
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
                let id = subscriptions[subscriptionIndex].nodes[nodeIndex].id
                if let latency = results[id] {
                    subscriptions[subscriptionIndex].nodes[nodeIndex].latency = latency
                }
            }
        }
        try? persist()
        let succeeded = results.values.filter { $0.outcome == .success }.count
        // 记下用了哪个端点：换端点后数字会整体平移，日志里没有这一条就无从解释。
        let host = endpoint.host ?? endpoint.absoluteString
        return outcome([.init(.info, "测速",
                              "完成 \(results.count) 个节点（经 \(host)）：\(succeeded) 可用 · \(results.count - succeeded) 失败")])
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
    public func archiveSingBoxLog(_ lines: [SingBoxLogLine]) {
        do {
            try logArchive.append(lines)
        } catch {
            CoreLog.configuration.error("归档日志失败：\(error.localizedDescription, privacy: .public)")
        }
        pruneIfDue()
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
        autoUpdatePaused = paused
        try? persist()
        return outcome([.init(.notice, "更新", paused ? "已暂停自动更新" : "已恢复自动更新")])
    }

    // MARK: - 落盘

    private func persist() throws {
        try stateStore.save(RouteBarState(subscriptions: subscriptions, autoUpdatePaused: autoUpdatePaused))
    }

    enum SubscriptionError: LocalizedError {
        case empty
        var errorDescription: String? { "订阅中没有可用的 VLESS、SS、Trojan、VMess 或 Hysteria2 节点" }
    }
}
