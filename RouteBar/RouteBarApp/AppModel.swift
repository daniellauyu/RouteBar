import Combine
import Foundation
import SwiftUI

/// 应用视图模型：把引擎 `SubscriptionCoordinator` 产出的状态转给界面。
///
/// 这里**不持有业务可变状态**——订阅、节点、服务状态全在引擎里，界面拿到的永远是
/// 引擎给的整份 `AppViewState` 快照。AppModel 只留纯界面状态（当前选中项、进度、弹窗）。
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state: AppViewState?

    // 界面状态
    @Published var selectedSection: AppSection = .overview
    @Published var selectedSubscriptionID: UUID?
    @Published var selectedNodeID: String?
    @Published var subscriptionSearchText = ""
    @Published var nodeSearchText = ""
    @Published var isUpdating = false
    @Published var updateProgress = 0.0
    @Published var testingNodeIDs: Set<String> = []
    @Published var alertMessage: String?
    @Published var singBoxLogText = ""
    @Published var singBoxErrorLogText = ""
    @Published private(set) var currentWindowDimensions = WindowDimensions(width: 0, height: 0)

    private let coordinator = SubscriptionCoordinator()
    private let log = RuntimeLog.shared
    private var schedulerTask: Task<Void, Never>?
    private var regenerationTask: Task<Void, Never>?
    private var runtimePathsCache: RuntimePaths = RuntimePaths()

    init() {
        log.info("生命周期", "RouteBar 启动")
    }

    // MARK: - 生命周期

    func bootstrap() async {
        apply(await coordinator.bootstrap())
        runtimePathsCache = await coordinator.paths
        // 监听状态是异步到达的，拉一次只能拿到「那一刻」的样子。订阅那一步是否算完成、
        // 服务页显示服务中还是端口冲突，都读这两个字段，所以让服务器变一次推一次。
        await server.observeState { [weak self] running, error in
            await self?.applySubscriptionState(running: running, error: error)
        }
        await syncServer()
        await refreshLogs()
        startScheduler()
        // 首次启动时不能只依赖调度器：它 30 秒后才第一次检查，而刚添加过订阅
        // （或从 Mihomo 导入过）的用户期待打开就能看到节点。
        await runDueUpdates()
    }

    /// 窗口重新激活或系统唤醒后：状态可能已被外部改变（手动 launchctl、Surge 重装）。
    func appBecameActive() {
        Task {
            apply(await coordinator.refreshServiceState())
            await refreshLogs()
            await runDueUpdates()
        }
    }

    private func startScheduler() {
        guard schedulerTask == nil else { return }
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                await self.runDueUpdates()
            }
        }
    }

    private func runDueUpdates() async {
        guard !isUpdating else { return }
        let due = await coordinator.dueSubscriptionIDs()
        guard !due.isEmpty else { return }
        log.info("更新", "\(due.count) 个订阅到期，开始自动更新")
        await runUpdates(due, regenerateAfter: true, initiatedByUser: false)
    }

    // MARK: - 状态应用

    /// 把引擎结果转成界面状态并写日志。是否弹窗由发起操作的调用点决定，后台任务只记日志。
    @discardableResult
    private func apply(_ outcome: CoordinatorOutcome, alertOnError: Bool = false) -> [String] {
        state = outcome.state
        for message in outcome.messages {
            log.log(message.level, message.category, message.text)
        }
        let errors = outcome.messages.filter { $0.level == .error }.map(\.text)
        if alertOnError { presentErrors(errors) }
        if let selectedSubscriptionID,
           !outcome.state.subscriptions.contains(where: { $0.id == selectedSubscriptionID }) {
            self.selectedSubscriptionID = nil
        }
        if let selectedNodeID,
           !outcome.state.mergedNodes.contains(where: { $0.id == selectedNodeID }) {
            self.selectedNodeID = nil
        }
        return errors
    }

    private func presentErrors(_ errors: [String]) {
        guard !errors.isEmpty else { return }
        alertMessage = errors.joined(separator: "\n\n")
    }

    // MARK: - 派生视图数据

    var subscriptions: [SubscriptionRecord] { state?.subscriptions ?? [] }
    var mergedNodes: [ProxyNode] { state?.mergedNodes ?? [] }
    var mappedNodes: [PortMappedNode] { state?.mappedNodes ?? [] }
    var serviceState: ServiceState { state?.serviceState ?? .stopped }
    var environment: RouteBarEnvironmentReport? { state?.environment }
    var settings: RouteBarSettings { state?.settings ?? RouteBarSettings.defaults() }
    var overall: OverallStatus { state?.overall ?? .stopped }
    var menuBarSummary: String { state?.menuBarSummary ?? "正在启动…" }
    var healthMessages: [String] { state?.healthMessages ?? [] }
    var nextUpdateDate: Date? { state?.nextUpdateDate }
    var autoUpdatePaused: Bool { state?.autoUpdatePaused ?? false }
    var enabledNodeCount: Int { state?.enabledNodes.count ?? 0 }
    var rawNodeCount: Int { state?.rawNodeCount ?? 0 }
    var deduplicatedCount: Int { state?.deduplicatedCount ?? 0 }
    var deduplicationRate: Double { state?.deduplicationRate ?? 0 }
    var testedNodeCount: Int { state?.testedNodeCount ?? 0 }
    var failedLatencyCount: Int { state?.failedLatencyCount ?? 0 }
    var failedSubscriptionCount: Int { state?.failedSubscriptionCount ?? 0 }
    var runtimePaths: RuntimePaths { runtimePathsCache }
    /// 当前生效的节点命名规则。与写进 Surge 配置的那一份同源（都出自快照）。
    var nodeNaming: NodeNaming { state?.nodeNaming ?? .default }

    /// 首次使用的分步清单。
    ///
    /// 状态散在三处——环境自检在引擎快照里、本地服务是否在监听只有 AppModel 知道、
    /// 登录项要现问系统——所以在这里汇总，判定顺序本身留在 Domain。
    var setupChecklist: SetupChecklist {
        SetupChecklist(
            environment: environment ?? RouteBarEnvironmentReport(paths: runtimePaths) { _ in false },
            subscriptionCount: subscriptions.count,
            outputMode: settings.surgeOutputMode,
            subscriptionServing: subscriptionServing,
            subscriptionURL: subscriptionURL,
            serviceRunning: serviceState.isRunning,
            launchesAtLogin: launchesAtLogin)
    }

    /// 登录项的真实状态。
    ///
    /// 放在这里而不是各视图各存一份 `@State`：设置页的开关和概览页的引导都要读它，
    /// 各自持有的话，在一处打开后另一处会继续显示「未开启」，直到那个视图碰巧重建。
    /// `register()` 成功不等于自启已生效（可能停在 `requiresApproval`），所以只信 `LoginItem.state`。
    @Published private(set) var loginItemState = LoginItem.state

    var launchesAtLogin: Bool { loginItemState.isOn }

    func refreshLaunchAtLogin() {
        loginItemState = LoginItem.state
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        loginItemState = LoginItem.setEnabled(enabled)
    }

    var filteredSubscriptions: [SubscriptionRecord] {
        guard !subscriptionSearchText.isEmpty else { return subscriptions }
        return subscriptions.filter {
            $0.name.localizedCaseInsensitiveContains(subscriptionSearchText)
                || $0.note.localizedCaseInsensitiveContains(subscriptionSearchText)
        }
    }

    var selectedSubscription: SubscriptionRecord? {
        subscriptions.first { $0.id == selectedSubscriptionID }
    }

    var selectedNode: ProxyNode? {
        mergedNodes.first { $0.id == selectedNodeID }
    }

    func sourceNames(for node: ProxyNode) -> [String] {
        subscriptions.filter { node.sourceIDs.contains($0.id) }.map(\.name)
    }

    /// 侧栏徽标：只给「数量本身是信息」的页加，避免侧栏变成一排数字。
    func badge(for section: AppSection) -> Int? {
        switch section {
        case .subscriptions: subscriptions.isEmpty ? nil : subscriptions.count
        case .nodes: mergedNodes.isEmpty ? nil : mergedNodes.count
        case .setup: setupChecklist.remainingRequiredCount > 0 ? setupChecklist.remainingRequiredCount : nil
        // 还没配完时不再单独标环境页：那几项缺失正是引导里的前几步，两个数字同时挂在
        // 侧栏上只会让人以为有两批不同的事要做。配完之后路径再出问题，它照常亮。
        case .environment:
            setupChecklist.remainingRequiredCount > 0
                ? nil
                : environment.map(\.missingCount).flatMap { $0 > 0 ? $0 : nil }
        default: nil
        }
    }

    // MARK: - 订阅操作

    func subscriptionURL(for subscription: SubscriptionRecord) async -> String {
        await coordinator.subscriptionURL(for: subscription.id)
    }

    func saveSubscription(id: UUID?, name: String, url: String, note: String, interval: Int,
                          nodeNameTemplate: String? = nil) {
        Task {
            do {
                try await saveSubscriptionAsync(id: id, name: name, url: url, note: note,
                                                interval: interval, nodeNameTemplate: nodeNameTemplate)
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    func saveSubscriptionAsync(id: UUID?, name: String, url: String, note: String, interval: Int,
                               nodeNameTemplate: String? = nil) async throws {
        do {
            let savedID = try await coordinator.saveSubscription(id: id, name: name, url: url,
                                                                 note: note, interval: interval,
                                                                 nodeNameTemplate: nodeNameTemplate)
            selectedSubscriptionID = savedID
            log.notice("订阅", "已保存订阅「\(name)」")
            await runUpdates([savedID], regenerateAfter: true, initiatedByUser: true)
        } catch {
            log.error("订阅", "保存订阅失败：\(error.localizedDescription)")
            throw error
        }
    }

    func delete(_ subscription: SubscriptionRecord) {
        Task { await deleteSubscription(subscription.id) }
    }

    func setSubscriptionEnabled(_ enabled: Bool, for id: UUID) {
        Task { await applySubscriptionEnabled(enabled, id: id) }
    }

    func setNodeEnabled(_ enabled: Bool, id: String) {
        Task { await applyNodeEnabled(enabled, id: id) }
    }

    // 可等待的版本。SwiftUI 的按钮不关心什么时候结束（上面那几个包一层 Task 就够），
    // 但 HTTP 请求必须等动作真正完成才能把新快照写进响应体，否则网页拿到的是改动前的状态。

    func deleteSubscription(_ id: UUID) async {
        apply(await coordinator.delete(id), alertOnError: true)
    }

    func applySubscriptionEnabled(_ enabled: Bool, id: UUID) async {
        apply(await coordinator.setSubscriptionEnabled(enabled, for: id), alertOnError: true)
        scheduleRegeneration()
    }

    func applyNodeEnabled(_ enabled: Bool, id: String) async {
        apply(await coordinator.setNodeEnabled(enabled, id: id), alertOnError: true)
        scheduleRegeneration()
    }

    /// 连续开关节点/订阅时只在最后一次改动后重装一次配置。
    private func scheduleRegeneration() {
        regenerationTask?.cancel()
        regenerationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard let self else { return }
            apply(await coordinator.regenerate(), alertOnError: true)
            regenerationTask = nil
        }
    }

    // MARK: - 更新

    func updateAll() async {
        guard !isUpdating else { return }
        await runUpdates(await coordinator.enabledSubscriptionIDs(), regenerateAfter: true, initiatedByUser: true)
    }

    func update(_ id: UUID) async {
        guard !isUpdating else { return }
        await runUpdates([id], regenerateAfter: true, initiatedByUser: true)
    }

    /// 逐条更新并即时刷新界面：每条完成就应用一次快照，进度条和订阅状态实时可见，
    /// 而不是全部跑完才一次性刷新。
    private func runUpdates(_ ids: [UUID], regenerateAfter: Bool, initiatedByUser: Bool) async {
        // 外层入口可能在 guard 后跨 actor await；恢复时必须在这里再次原子地抢占更新权。
        guard !ids.isEmpty, !isUpdating else { return }
        regenerationTask?.cancel()
        regenerationTask = nil
        isUpdating = true
        updateProgress = 0
        defer {
            isUpdating = false
            updateProgress = 0
        }
        var errors: [String] = []
        for (offset, id) in ids.enumerated() {
            errors += apply(await coordinator.markUpdating(id))
            errors += apply(await coordinator.update(id))
            updateProgress = Double(offset + 1) / Double(ids.count)
        }
        if regenerateAfter {
            errors += apply(await coordinator.regenerate())
        }
        if initiatedByUser { presentErrors(errors) }
    }

    func toggleAutoUpdate() {
        Task { await setAutoUpdatePaused(!autoUpdatePaused) }
    }

    func setAutoUpdatePaused(_ paused: Bool) async {
        apply(await coordinator.setAutoUpdatePaused(paused))
    }

    // MARK: - 测速

    func testAllNodes() async {
        let mapped = await coordinator.mappedNodes()
        await runLatencyTest(mapped)
    }

    func testNode(_ id: String) async {
        let mapped = await coordinator.mappedNodes().filter { $0.node.id == id }
        await runLatencyTest(mapped)
    }

    /// 测速端点，来自设置（`@AppStorage("latencyTestURL")`），非法值回落到默认端点。
    var latencyTestURL: URL {
        LatencyTestEndpoint.resolve(UserDefaults.standard.string(forKey: "latencyTestURL") ?? "")
    }

    /// 每节点采样次数，来自设置。1 表示只测一次（快，但结果会跳）。
    var latencySamples: Int {
        let stored = UserDefaults.standard.integer(forKey: "latencySamples")
        return (1...5).contains(stored) ? stored : 3
    }

    private func runLatencyTest(_ mapped: [PortMappedNode]) async {
        guard !mapped.isEmpty else {
            alertMessage = "没有可测试的启用节点。"
            return
        }
        guard serviceState.isRunning else {
            alertMessage = "sing-box 未在运行，测速要经过本地端口，请先启动服务。"
            return
        }
        let ids = Set(mapped.map(\.node.id))
        testingNodeIDs.formUnion(ids)
        apply(await coordinator.testNodes(mapped, testURL: latencyTestURL, samples: latencySamples), alertOnError: true)
        testingNodeIDs.subtract(ids)
    }

    // MARK: - 服务

    func restartService() { Task { await startServiceAsync() } }
    func stopService() { Task { await stopServiceAsync() } }
    func refreshService() { Task { await refreshServiceAsync() } }
    func regenerate() { Task { await regenerateAsync() } }

    func startServiceAsync() async {
        apply(await coordinator.restartService(), alertOnError: true)
        await refreshLogs()
    }

    func stopServiceAsync() async {
        apply(await coordinator.stopService(), alertOnError: true)
    }

    func refreshServiceAsync() async {
        apply(await coordinator.refreshServiceState(), alertOnError: true)
        await refreshLogs()
    }

    func regenerateAsync() async {
        apply(await coordinator.regenerate(forceRestart: true), alertOnError: true)
    }

    func refreshLogs() async {
        let tails = await coordinator.logTails()
        singBoxLogText = tails.standard
        singBoxErrorLogText = tails.error
    }

    // MARK: - 设置

    func saveSettings(_ newSettings: RouteBarSettings) {
        Task { await saveSettingsAsync(newSettings) }
    }

    /// 可等待的版本：HTTP 请求要等设置真正落盘之后才能回快照。
    func saveSettingsAsync(_ newSettings: RouteBarSettings) async {
        let previous = settings
        apply(await coordinator.saveSettings(newSettings), alertOnError: true)
        runtimePathsCache = await coordinator.paths
        // 只在监听参数真的变了时才重起服务。无条件重起的话，从网页改一个与服务无关的
        // 设置（比如节点命名）会把正在响应这次请求的那个监听器一起拆掉。
        let listenerChanged = previous.subscriptionPort != newSettings.subscriptionPort
            || previous.subscriptionToken != newSettings.subscriptionToken
            || previous.surgeOutputMode != newSettings.surgeOutputMode
        if listenerChanged { await server.stop() }
        await syncServer()
        await refreshLogs()
    }

    // MARK: - 本地服务（订阅地址 + Web 界面）

    @Published private(set) var subscriptionServing = false
    @Published private(set) var subscriptionError: String?

    var subscriptionURL: String { settings.subscriptionURL }
    var webInterfaceURL: String { settings.webInterfaceURL }

    /// 服务器挂在 AppModel 而不是引擎上。
    ///
    /// 因为路由要调的是 AppModel 的动词（防抖重装、更新进度、测速端点），挂在引擎上就成了
    /// 引擎 → 服务器 → 路由 → 引擎的环。放在这里，依赖是单向的：AppModel → 服务器、
    /// AppModel → 引擎。
    private let server = LocalHTTPServer()

    func syncServer() async {
        let settings = self.settings
        guard settings.surgeOutputMode.servesSubscription else {
            await server.stop()
            subscriptionServing = false
            subscriptionError = nil
            return
        }
        let router = APIRouter(token: settings.subscriptionToken,
                               port: settings.subscriptionPort,
                               host: self)
        await server.start(port: settings.subscriptionPort, handler: router.handler())
        await refreshSubscriptionStatus()
    }

    /// 监听要等 `NWListener` 进入 `.ready` 才算数，`start` 返回时通常还没到，
    /// 所以状态得单独取一次而不能拿 `start` 的返回值。
    ///
    /// 正常情况下服务器会自己推（见 `bootstrap` 里的 `observeState`），这里只是补一次
    /// 兜底：网页 API 可能在窗口从未打开过时就被访问。
    func refreshSubscriptionStatus() async {
        applySubscriptionState(running: await server.isRunning, error: await server.lastError)
    }

    private func applySubscriptionState(running: Bool, error: String?) {
        subscriptionServing = running
        subscriptionError = error
    }

    // MARK: - LaunchAgent

    func launchAgentState() async -> LaunchAgentState {
        await coordinator.launchAgentState()
    }

    func launchAgentPreview() async -> String {
        await coordinator.launchAgentPreview()
    }

    func installLaunchAgent(allowOverwritingForeignFile: Bool) async {
        apply(await coordinator.installLaunchAgent(allowOverwritingForeignFile: allowOverwritingForeignFile),
              alertOnError: true)
        await refreshLogs()
    }

    func createRequiredDirectories() {
        Task { apply(await coordinator.createRequiredDirectories(), alertOnError: true) }
    }

    /// 重新探测 sing-box 的位置（用户刚装完）。
    ///
    /// 只动这一个字段，不整份回落到默认设置——用户可能已经改过 Surge 配置路径或 Label，
    /// 那些不该因为「重新检测一下二进制」而被冲掉。
    func redetectSingBox() {
        let probed = RouteBarSettings.singBoxSearchPaths.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        guard let probed, probed != settings.singBoxBinaryPath else {
            // 路径没变也要重算一次自检：用户装的可能正是当前这条路径，
            // 不刷新的话界面还停在「未找到」，看着像没生效。
            refreshService()
            return
        }
        var updated = settings
        updated.singBoxBinaryPath = probed
        log.notice("环境", "已探测到 sing-box：\(probed)")
        saveSettings(updated)
    }

    func updateWindowDimensions(_ dimensions: WindowDimensions) {
        currentWindowDimensions = dimensions
    }

    func saveCurrentWindowAsDefault() {
        guard currentWindowDimensions.width > 0, currentWindowDimensions.height > 0 else { return }
        UserDefaults.standard.set(currentWindowDimensions.width, forKey: "customWindowWidth")
        UserDefaults.standard.set(currentWindowDimensions.height, forKey: "customWindowHeight")
        UserDefaults.standard.set(DefaultWindowSize.custom.rawValue, forKey: "defaultWindowSize")
        log.notice("设置", "默认窗口尺寸已设为 \(currentWindowDimensions.label)")
    }

    // MARK: - 文件操作

    func pathExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func open(_ url: URL) {
        if pathExists(url) {
            NSWorkspace.shared.open(url)
        } else {
            alertMessage = "文件不存在：\(url.path)"
        }
    }

    func reveal(_ url: URL) {
        if pathExists(url) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    /// 在默认浏览器里打开 Web 界面。
    func openWebInterface() {
        guard settings.surgeOutputMode.servesSubscription else {
            alertMessage = "Web 界面依赖本地服务，请先在「通用 → 输出到 Surge」里选择包含订阅地址的方式。"
            return
        }
        guard let url = URL(string: webInterfaceURL) else { return }
        NSWorkspace.shared.open(url)
    }

    func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - 导航

    func selectSubscription(_ id: UUID) {
        selectedSubscriptionID = id
        selectedSection = .subscriptions
    }

    func selectNode(_ id: String) {
        selectedNodeID = id
        selectedSection = .nodes
    }
}

// MARK: - Web API

/// 每一项都直接转调上面已有的方法——**这里没有一行业务逻辑**。
///
/// 这正是整个 API 层的设计前提：网页和窗口驱动的是同一组动词，所以节点防抖重装、
/// 更新进度、测速用哪个端点这些行为在两个前端上必然一致。若让路由直连引擎，
/// 网页上的操作会绕过这些包装，行为悄悄分叉，而这种差异极难在测试里发现。
extension AppModel: RouteBarAPIHost {
    func apiSnapshot() async -> APISnapshot {
        // 服务器可能在窗口没打开时被访问，顺手刷新一次监听状态。
        await refreshSubscriptionStatus()
        return APISnapshot(state: currentViewState,
                           subscriptionServing: subscriptionServing,
                           subscriptionError: subscriptionError)
    }

    /// 引擎还没产出过快照时（窗口从未打开）兜一份空状态，API 不至于 500。
    private var currentViewState: AppViewState {
        state ?? AppViewState(subscriptions: [], serviceState: .stopped,
                              environment: RouteBarEnvironmentReport(paths: runtimePaths) { _ in false },
                              settings: settings, autoUpdatePaused: false)
    }

    /// Surge 要拉的策略集。
    ///
    /// 按请求现算，不缓存字符串：缓存的那一份会在「配置未变化、跳过安装」这条分支上
    /// 停留在上一轮的内容。快照里的端口映射与即将写进 sing-box 的编号同源，现算永远对得上。
    func apiPolicyList() async -> String {
        ConfigurationGenerator.surgePolicyLines(mappedNodes, naming: nodeNaming)
    }

    func apiSaveSubscription(_ input: APISubscriptionInput) async throws {
        let existingID = input.id.flatMap(UUID.init(uuidString:))
        let existing = existingID.flatMap { id in subscriptions.first { $0.id == id } }
        // 编辑时地址留空表示「保持原样」——网页不显示已存的地址（它含机场凭据，
        // 只在钥匙串里），所以不能把空串当成「清空地址」。
        var url = input.url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if url.isEmpty {
            guard let existingID else { throw APIInputError.missingURL }
            url = await coordinator.subscriptionURL(for: existingID)
            guard !url.isEmpty else { throw APIInputError.missingURL }
        }
        guard let parsed = URL(string: url), parsed.scheme == "http" || parsed.scheme == "https" else {
            throw APIInputError.invalidURL
        }
        try await saveSubscriptionAsync(id: existingID,
                                        name: input.name.trimmingCharacters(in: .whitespaces),
                                        url: url,
                                        note: input.note ?? existing?.note ?? "",
                                        interval: input.intervalHours ?? existing?.updateIntervalHours ?? 6,
                                        nodeNameTemplate: input.nodeNameTemplate)
    }

    /// 全局模板走设置：它和端口、输出方式一样是应用级配置，存在 settings.json 里。
    func apiSetNodeNameTemplate(_ template: String) async {
        var updated = settings
        updated.nodeNameTemplate = NodeNaming.normalized(template)
        await saveSettingsAsync(updated)
    }

    func apiPreviewNodeNames(_ template: String) async -> APINamingPreview {
        APINamingPreview(state: currentViewState, template: template)
    }

    func apiDeleteSubscription(_ id: UUID) async { await deleteSubscription(id) }
    func apiSetSubscriptionEnabled(_ enabled: Bool, id: UUID) async { await applySubscriptionEnabled(enabled, id: id) }
    func apiUpdateSubscription(_ id: UUID) async { await update(id) }
    func apiUpdateAll() async { await updateAll() }
    func apiSetNodeEnabled(_ enabled: Bool, id: String) async { await applyNodeEnabled(enabled, id: id) }
    func apiTestNode(_ id: String) async { await testNode(id) }
    func apiTestAllNodes() async { await testAllNodes() }
    func apiRegenerate() async { await regenerateAsync() }
    func apiStartService() async { await startServiceAsync() }
    func apiStopService() async { await stopServiceAsync() }
    func apiRefreshService() async { await refreshServiceAsync() }
    func apiSetAutoUpdatePaused(_ paused: Bool) async { await setAutoUpdatePaused(paused) }

    func apiLogs() async -> APILogs {
        await refreshLogs()
        let recent = Array(log.entries.suffix(200))
        return APILogs(singBoxStandard: singBoxLogText,
                       singBoxError: singBoxErrorLogText,
                       runtime: recent.isEmpty ? [] : log.exportText(recent).components(separatedBy: "\n"))
    }

    enum APIInputError: LocalizedError {
        case missingURL
        case invalidURL

        var errorDescription: String? {
            switch self {
            case .missingURL: "缺少订阅地址"
            case .invalidURL: "订阅地址必须是 http 或 https 链接"
            }
        }
    }
}
