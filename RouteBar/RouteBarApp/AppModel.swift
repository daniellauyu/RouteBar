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
    private var runtimePathsCache: RuntimePaths = RuntimePaths()

    init() {
        log.info("生命周期", "RouteBar 启动")
    }

    // MARK: - 生命周期

    func bootstrap() async {
        apply(await coordinator.bootstrap())
        runtimePathsCache = await coordinator.paths
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
        await runUpdates(due, regenerateAfter: true)
    }

    // MARK: - 状态应用

    /// 把引擎结果转成界面状态：替换快照 + 把消息写进运行日志。
    private func apply(_ outcome: CoordinatorOutcome) {
        state = outcome.state
        for message in outcome.messages {
            log.log(message.level, message.category, message.text)
            // 错误级消息同时弹窗，用户不必自己去日志页找原因。
            if message.level == .error { alertMessage = message.text }
        }
        if let selectedSubscriptionID,
           !outcome.state.subscriptions.contains(where: { $0.id == selectedSubscriptionID }) {
            self.selectedSubscriptionID = nil
        }
        if let selectedNodeID,
           !outcome.state.mergedNodes.contains(where: { $0.id == selectedNodeID }) {
            self.selectedNodeID = nil
        }
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
                let savedID = try await coordinator.saveSubscription(id: id, name: name, url: url,
                                                                     note: note, interval: interval)
                selectedSubscriptionID = savedID
                log.notice("订阅", "已保存订阅「\(name)」")
                await runUpdates([savedID], regenerateAfter: true)
            } catch {
                alertMessage = error.localizedDescription
                log.error("订阅", "保存订阅失败：\(error.localizedDescription)")
            }
        }
    }

    func delete(_ subscription: SubscriptionRecord) {
        Task { apply(await coordinator.delete(subscription.id)) }
    }

    func setSubscriptionEnabled(_ enabled: Bool, for id: UUID) {
        Task { apply(await coordinator.setSubscriptionEnabled(enabled, for: id)) }
    }

    func setNodeEnabled(_ enabled: Bool, id: String) {
        Task { apply(await coordinator.setNodeEnabled(enabled, id: id)) }
    }

    // MARK: - 更新

    func updateAll() async {
        guard !isUpdating else { return }
        await runUpdates(await coordinator.enabledSubscriptionIDs(), regenerateAfter: true)
    }

    func update(_ id: UUID) async {
        guard !isUpdating else { return }
        await runUpdates([id], regenerateAfter: true)
    }

    /// 逐条更新并即时刷新界面：每条完成就应用一次快照，进度条和订阅状态实时可见，
    /// 而不是全部跑完才一次性刷新。
    private func runUpdates(_ ids: [UUID], regenerateAfter: Bool) async {
        guard !ids.isEmpty else { return }
        isUpdating = true
        updateProgress = 0
        for (offset, id) in ids.enumerated() {
            apply(await coordinator.markUpdating(id))
            apply(await coordinator.update(id))
            updateProgress = Double(offset + 1) / Double(ids.count)
        }
        if regenerateAfter {
            apply(await coordinator.regenerate())
        }
        isUpdating = false
        updateProgress = 0
    }

    func toggleAutoUpdate() {
        Task { apply(await coordinator.setAutoUpdatePaused(!autoUpdatePaused)) }
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
        apply(await coordinator.testNodes(mapped, testURL: latencyTestURL, samples: latencySamples))
        testingNodeIDs.subtract(ids)
    }

    // MARK: - 服务

    func restartService() {
        Task { apply(await coordinator.restartService()); await refreshLogs() }
    }

    func stopService() {
        Task { apply(await coordinator.stopService()) }
    }

    func refreshService() {
        Task { apply(await coordinator.refreshServiceState()); await refreshLogs() }
    }

    func regenerate() {
        Task { apply(await coordinator.regenerate()) }
    }

    func refreshLogs() async {
        let tails = await coordinator.logTails()
        singBoxLogText = tails.standard
        singBoxErrorLogText = tails.error
    }

    // MARK: - 设置

    func saveSettings(_ newSettings: RouteBarSettings) {
        Task {
            apply(await coordinator.saveSettings(newSettings))
            runtimePathsCache = await coordinator.paths
            await refreshLogs()
        }
    }

    func createRequiredDirectories() {
        Task { apply(await coordinator.createRequiredDirectories()) }
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
