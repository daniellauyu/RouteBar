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
        case .environment: environment.map(\.missingCount).flatMap { $0 > 0 ? $0 : nil }
        default: nil
        }
    }

    // MARK: - 订阅操作

    func subscriptionURL(for subscription: SubscriptionRecord) async -> String {
        await coordinator.subscriptionURL(for: subscription.id)
    }

    func saveSubscription(id: UUID?, name: String, url: String, note: String, interval: Int) {
        Task {
            do {
                try await saveSubscriptionAsync(id: id, name: name, url: url, note: note, interval: interval)
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    func saveSubscriptionAsync(id: UUID?, name: String, url: String, note: String, interval: Int) async throws {
        do {
            let savedID = try await coordinator.saveSubscription(id: id, name: name, url: url,
                                                                 note: note, interval: interval)
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
        Task {
            apply(await coordinator.saveSettings(newSettings), alertOnError: true)
            runtimePathsCache = await coordinator.paths
            // 端口、令牌或输出方式可能都变了，让服务按新设置重来一遍。
            await server.stop()
            await syncServer()
            await refreshLogs()
        }
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
    func refreshSubscriptionStatus() async {
        subscriptionServing = await server.isRunning
        subscriptionError = await server.lastError
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
        let current = state ?? AppViewState(subscriptions: [], serviceState: .stopped,
                                            environment: RouteBarEnvironmentReport(paths: runtimePaths) { _ in false },
                                            settings: settings, autoUpdatePaused: false)
        return APISnapshot(state: current,
                           subscriptionServing: subscriptionServing,
                           subscriptionError: subscriptionError)
    }

    /// Surge 要拉的策略集。
    ///
    /// 按请求现算，不缓存字符串：缓存的那一份会在「配置未变化、跳过安装」这条分支上
    /// 停留在上一轮的内容。快照里的端口映射与即将写进 sing-box 的编号同源，现算永远对得上。
    func apiPolicyList() async -> String {
        ConfigurationGenerator.surgePolicyLines(mappedNodes)
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
                                        interval: input.intervalHours ?? existing?.updateIntervalHours ?? 6)
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
