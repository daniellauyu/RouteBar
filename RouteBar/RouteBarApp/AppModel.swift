import AppKit
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
    @Published var subscriptionProtocolFilter: ProxyProtocol?
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
    private var pendingUpdateIDs: Set<UUID> = []
    private var pendingUpdateNeedsRegeneration = false
    private var pendingUpdateInitiatedByUser = false
    private var logReloadTask: Task<Void, Never>?
    private var ingestInProgress = false
    private var runtimePathsCache: RuntimePaths = RuntimePaths()

    init() {
        // 归档管道要在写下第一条之前装好，否则「RouteBar 启动」这条——回溯时用来
        // 定位「那天它到底跑起来没有」的那条——进不了当天的归档。
        installLogArchiver()
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
                guard !Task.isCancelled else { return }
                self.apply(await self.coordinator.refreshServiceState())
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
           !outcome.state.displayedNodes.contains(where: { $0.id == selectedNodeID }) {
            self.selectedNodeID = nil
        }
        return errors
    }

    private func presentErrors(_ errors: [String]) {
        guard !errors.isEmpty else { return }
        // 一键流程自己会把每一步的成败写进清单和日志页，最后还给一份总结。
        // 这时再逐步弹窗，等于让用户在七个模态框之间点确定才能看到结果。
        guard !setupRun.isRunning else { return }
        alertMessage = errors.joined(separator: "\n\n")
    }

    // MARK: - 派生视图数据

    var subscriptions: [SubscriptionRecord] { state?.subscriptions ?? [] }
    var mergedNodes: [ProxyNode] { state?.mergedNodes ?? [] }
    var mappedNodes: [PortMappedNode] { state?.mappedNodes ?? [] }
    var displayedNodes: [DisplayedNode] { state?.displayedNodes ?? [] }
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
        return subscriptions.filter { subscription in
            let matchesSearch = subscriptionSearchText.isEmpty
                || subscription.name.localizedCaseInsensitiveContains(subscriptionSearchText)
                || subscription.note.localizedCaseInsensitiveContains(subscriptionSearchText)
            let matchesProtocol = subscriptionProtocolFilter.map { type in
                subscription.nodes.contains { $0.protocolType == type }
            } ?? true
            return matchesSearch && matchesProtocol
        }
    }

    var selectedSubscription: SubscriptionRecord? {
        subscriptions.first { $0.id == selectedSubscriptionID }
    }

    var selectedNode: ProxyNode? {
        selectedDisplayedNode?.node
    }

    var selectedDisplayedNode: DisplayedNode? {
        displayedNodes.first { $0.id == selectedNodeID }
    }

    func sourceNames(for node: ProxyNode) -> [String] {
        subscriptions.filter { node.sourceIDs.contains($0.id) }.map(\.name)
    }

    /// 侧栏徽标：只给「数量本身是信息」的页加，避免侧栏变成一排数字。
    func badge(for section: AppSection) -> Int? {
        switch section {
        case .subscriptions: subscriptions.isEmpty ? nil : subscriptions.count
        case .nodes: displayedNodes.isEmpty ? nil : displayedNodes.count
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
        do { return try await coordinator.subscriptionURL(for: subscription.id) }
        catch {
            alertMessage = "读取订阅地址失败：\(error.localizedDescription)"
            return ""
        }
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
        if !subscriptions.contains(where: { $0.id == id }) {
            apply(await coordinator.regenerate(), alertOnError: true)
        }
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
        guard !ids.isEmpty else { return }
        if isUpdating {
            pendingUpdateIDs.formUnion(ids)
            pendingUpdateNeedsRegeneration = pendingUpdateNeedsRegeneration || regenerateAfter
            pendingUpdateInitiatedByUser = pendingUpdateInitiatedByUser || initiatedByUser
            return
        }
        regenerationTask?.cancel()
        regenerationTask = nil
        isUpdating = true
        updateProgress = 0
        defer {
            isUpdating = false
            updateProgress = 0
            if !pendingUpdateIDs.isEmpty {
                let next = Array(pendingUpdateIDs)
                let regenerate = pendingUpdateNeedsRegeneration
                let userInitiated = pendingUpdateInitiatedByUser
                pendingUpdateIDs.removeAll()
                pendingUpdateNeedsRegeneration = false
                pendingUpdateInitiatedByUser = false
                Task { await self.runUpdates(next, regenerateAfter: regenerate, initiatedByUser: userInitiated) }
            }
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
        let mapped = await coordinator.mappedNodes().filter { $0.node.entryID == id }
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

    // MARK: - 落地探测

    /// 正在探测落地的节点，用于在列表上转圈。与测速分开，两件事可以各转各的。
    @Published var probingGeoIDs: Set<String> = []

    func probeGeoForAllNodes() async {
        await runGeoProbe(await coordinator.mappedNodes())
    }

    func probeGeo(_ id: String) async {
        await runGeoProbe(await coordinator.mappedNodes().filter { $0.node.entryID == id })
    }

    /// 落地探测和测速一样要经本机端口出去，所以同样要求服务在跑。
    private func runGeoProbe(_ mapped: [PortMappedNode]) async {
        guard !mapped.isEmpty else {
            alertMessage = "没有可探测的启用节点。"
            return
        }
        guard serviceState.isRunning else {
            alertMessage = "sing-box 未在运行，落地探测要经过本地端口，请先启动服务。"
            return
        }
        let ids = Set(mapped.map(\.node.entryID))
        probingGeoIDs.formUnion(ids)
        apply(await coordinator.probeGeo(mapped), alertOnError: true)
        probingGeoIDs.subtract(ids)
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
        let ids = Set(mapped.map(\.node.entryID))
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
        await ingestSingBoxLog()
    }

    /// 日志页可见时的轮询入口：只把 sing-box 新写的行并进来。
    ///
    /// 不走 `refreshLogs()`：那还会把两份日志的末尾各 20 KB 读进 `singBoxLogText`，
    /// 而那两个字段只有「服务」页在用，几秒一次地重读纯属浪费。
    ///
    /// 需要轮询是因为 sing-box 那半边**没有推送**：它的日志是 launchd 交给它的一个文件，
    /// RouteBar 只能自己去看有没有变长。RouteBar 自己的记录走 `installLogArchiver`
    /// 是实时的——两边不一致时，用户看到的是「sing-box 那半边不动了」。
    func pollSingBoxLog() async {
        await ingestSingBoxLog()
    }

    /// sing-box 日志读到哪儿了。按字节偏移续读，见 `RuntimeManager.readNewLines`。
    ///
    /// 落盘保存（见 `LogArchiveStore.loadIngestOffset`）：只留在内存里的话每次启动都会
    /// 重读一遍并重新归档，同一批错误会按重启次数在归档里翻倍。
    private var singBoxLogOffset: UInt64 = 0
    private var singBoxLogOffsetLoaded = false

    /// 把 sing-box 新写的日志并进日志页。
    ///
    /// 只收 `.warning` 及以上。sing-box 的 INFO 是**每条连接一行**——真机上 35 天
    /// 43 万行，全放进来的话，1000 条的环形缓冲会在几秒内被连接记录填满，
    /// RouteBar 自己的事件一条都留不下，等于把这一页毁掉。生成的配置已经把级别
    /// 降到 warn，这里再挡一道：老机器上那份历史日志里仍然全是 INFO。
    private func ingestSingBoxLog() async {
        guard !ingestInProgress else { return }
        ingestInProgress = true
        defer { ingestInProgress = false }
        if !singBoxLogOffsetLoaded {
            singBoxLogOffset = await coordinator.ingestOffset()
            singBoxLogOffsetLoaded = true
        }
        let chunk = await coordinator.newSingBoxLog(since: singBoxLogOffset)
        // 偏移没动也没有新内容，就什么都不做。日志页是几秒一轮地调这个方法的，
        // 无条件回写偏移等于在用户盯着日志时每隔几秒写一次盘，而绝大多数轮次
        // sing-box 一个字节都没写。
        guard chunk.offset != singBoxLogOffset || !chunk.text.isEmpty else { return }
        let lines = SingBoxLogParser.parse(tail: chunk.text)
        // 先归档再筛：归档留全量（回溯「那天发生了什么」），内存缓冲只留要紧的。
        guard await coordinator.archiveSingBoxLog(lines) else { return }
        await coordinator.saveIngestOffset(chunk.offset)
        singBoxLogOffset = chunk.offset
        for line in lines where line.level >= .warning {
            log.ingest(line)
        }
        await reloadDayIfShowing(lines.compactMap(\.timestamp))
    }

    // MARK: - 日志归档

    @Published private(set) var logDates: [Date] = []
    /// 日志页正在看哪一天。默认今天。
    ///
    /// 一律用**当天零点**，不是「此刻」：日期选择器要拿它和归档日期比相等，而归档
    /// 日期是从文件名解析出来的零点。存着此刻的话永远比不中，选择器会显示成空的。
    @Published var viewingDay: Date = Calendar.current.startOfDay(for: .now) {
        didSet {
            guard oldValue != viewingDay else { return }
            Task { await loadDay() }
        }
    }
    @Published private(set) var dayEntries: [RuntimeLogEntry] = []

    /// 装上归档管道。启动时调一次。
    ///
    /// RouteBar 自己的记录也要进归档，否则日志页选「今天」只能看到 sing-box 那一半，
    /// 订阅更新、配置生成、服务控制这些事件全不见了——而排查时要看的恰恰是
    /// 这两条时间线怎么对上。
    private func installLogArchiver() {
        log.archiver = { [weak self] entry in
            guard let self else { return }
            let line = SingBoxLogLine(timestamp: entry.timestamp,
                                      level: entry.level,
                                      category: LogArchive.tag(routeBarCategory: entry.category),
                                      message: entry.message)
            Task {
                await self.coordinator.archiveSingBoxLog([line])
                await self.reloadDayIfShowing([entry.timestamp])
            }
        }
    }

    /// 刚归档的那批里只要有今天（或正在看的那天）的行，就把当前视图重读一遍。
    ///
    /// 判日期而不是无条件重读：翻着昨天的记录时，新来的今天的日志不该把视图顶掉。
    private func reloadDayIfShowing(_ timestamps: [Date]) async {
        let calendar = Calendar.current
        let touched = timestamps.contains { calendar.isDate($0, inSameDayAs: viewingDay) }
        guard touched, selectedSection == .logs, logReloadTask == nil else { return }
        logReloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            await self.loadDay()
            self.logReloadTask = nil
        }
    }

    func refreshLogDates() async {
        let today = Calendar.current.startOfDay(for: .now)
        var dates = await coordinator.archivedLogDates()
        // 今天必须在列表里，哪怕还没归档过任何东西（全新安装、或今天刚删过）：
        // 否则日期选择器是空的，而用户第一反应是「日志坏了」。
        if !dates.contains(today) { dates.insert(today, at: 0) }
        logDates = dates
        // 正在看的那天被保留期清掉了，就退回最近的一天。
        if !dates.contains(viewingDay), let newest = dates.first {
            viewingDay = newest
        }
        await loadDay()
    }

    private func loadDay() async {
        let day = viewingDay
        dayEntries = await coordinator.archivedLog(day).map { line in
            let (category, isRouteBar) = LogArchive.untag(line.category)
            return RuntimeLogEntry(timestamp: line.timestamp ?? day, level: line.level,
                                   category: category, message: line.message,
                                   source: isRouteBar ? .routeBar : .singBox)
        }
    }

    /// 删掉某一天的归档文件。
    func deleteLog(_ day: Date) {
        Task {
            apply(await coordinator.deleteArchivedLog(day), alertOnError: true)
            await refreshLogDates()
            await loadDay()
        }
    }

    /// 在访达里打开归档目录。
    ///
    /// 先建目录再打开：一次日志都没归档过时它还不存在，而那恰恰是用户最可能去
    /// 翻一翻的时候——直接开一个不存在的路径，访达什么反应都没有。
    func revealLogArchive() {
        Task {
            let directory = await coordinator.archivedLogDirectory()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        }
    }

    func archivedLogSizeText() async -> String {
        let size = await coordinator.archivedLogSize()
        guard size > 0 else { return "暂无归档" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    func clearSingBoxLogs() {
        Task {
            apply(await coordinator.clearSingBoxLogs(), alertOnError: true)
            // 文件被截断了，偏移必须跟着回到 0，否则下一次读会从一个已经不存在的
            // 位置开始，新写进来的日志要等文件重新长到那个长度才看得见。落盘的那份
            // 也要一起归零，不然下次启动又会读回旧偏移。
            singBoxLogOffset = 0
            await coordinator.saveIngestOffset(0)
            await refreshLogs()
        }
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

    // MARK: - 一键完成

    @Published private(set) var setupRun = SetupAutomationRun()

    func runSetupAutomation() { Task { await runSetupAutomationAsync() } }

    /// 按引导顺序把能代劳的步骤挨个做掉。
    ///
    /// 每一步都重新读一次 `setupChecklist`，而不是拿开跑那一刻的快照挨个跑：前一步会
    /// 改变后一步的判定（装完二进制环境自检才变绿、生成完配置服务才有东西可启动），
    /// 用旧快照的话，从第二步起判断的全是过期状态。
    ///
    /// 中途不弹窗、不中止：某一步失败不代表后面几步做不了（比如 sing-box 没装成，
    /// 目录和 LaunchAgent 照样该建好），全部跑完再一次性给结论。
    func runSetupAutomationAsync() async {
        guard !setupRun.isRunning else { return }
        let kinds = setupChecklist.steps.map(\.kind)
        setupRun = SetupAutomationRun(isRunning: true, totalSteps: kinds.count)
        log.notice("引导", "开始一键配置")

        for kind in kinds {
            guard let step = setupChecklist.steps.first(where: { $0.kind == kind }) else { continue }
            beginStep(kind)
            defer { setupRun.completedSteps += 1 }
            if let reason = step.manualReason {
                record(kind, .skipped(reason))
                continue
            }
            // LaunchAgent 是唯一「文件在也不等于做完了」的一步：装完 sing-box 之后
            // plist 里的二进制路径可能已经过时，所以让它自己再判一次内容。
            if step.isDone, kind != .launchAgent {
                record(kind, .done(step.done))
                continue
            }
            record(kind, .running)
            record(kind, await perform(kind))
        }

        endRun()
        let report = makeSetupReport()
        setupRun.report = report
        log.notice("引导", "一键配置结束：\(report.headline)")
    }

    /// 只补 sing-box 这一件事。
    ///
    /// 清单里那一步自己的按钮用它：想补一个二进制的人不该顺带被改掉 LaunchAgent 和
    /// 开机自启——那是他按「一键完成」时才表达的意图。
    func installSingBoxOnly() { Task { await runSingleSetupStep(.singBox) } }

    /// 重跑单独一步。失败的那一行旁边那颗「重试」用它。
    ///
    /// 失败常常是一次性的（网络抖了、brew 的锁没释放），重跑一次就好；为此让用户
    /// 把整条流水线再走一遍，等于逼他把已经成功的六步重做。
    func retrySetupStep(_ kind: SetupStep.Kind) { Task { await runSingleSetupStep(kind) } }

    private func runSingleSetupStep(_ kind: SetupStep.Kind) async {
        guard !setupRun.isRunning else { return }
        // 单步不出总结条：用户只想补这一件事，回他一句「还差 3 步」是答非所问。
        // 但进度照给——单独装 sing-box 一样能跑好几分钟。
        setupRun = SetupAutomationRun(isRunning: true, totalSteps: 1)
        beginStep(kind)
        record(kind, .running)
        record(kind, await perform(kind))
        setupRun.completedSteps = 1
        endRun()
    }

    private func beginStep(_ kind: SetupStep.Kind) {
        setupRun.currentKind = kind
        setupRun.currentStartedAt = .now
        // 上一步的实时输出必须清掉：留着的话，下一步刚开始的几秒里，界面上挂的是
        // 上一步的最后一行，看着像这一步瞬间就干了别的事。
        setupRun.statusText = nil
        setupRun.fraction = nil
    }

    private func endRun() {
        setupRun.isRunning = false
        setupRun.currentKind = nil
        setupRun.currentStartedAt = nil
        setupRun.statusText = nil
        setupRun.fraction = nil
    }

    /// 收到当前步骤的一条实时进度。
    private func reportSetupProgress(_ message: String, fraction: Double?) {
        guard setupRun.isRunning else { return }
        setupRun.statusText = message
        setupRun.fraction = fraction
    }

    private func record(_ kind: SetupStep.Kind, _ outcome: SetupStepOutcome) {
        setupRun.outcomes[kind] = outcome
        let title = stepTitle(kind)
        switch outcome {
        case .running: break
        case .done(let text): log.notice("引导", "\(title)：\(text)")
        case .skipped(let text): log.info("引导", "\(title)（跳过）：\(text)")
        case .failed(let text): log.error("引导", "\(title)：\(Self.firstParagraph(text))")
        }
    }

    /// 只取第一段。
    ///
    /// 失败信息后面可能跟着一整段手工补救步骤（sing-box 装不上时就是这样）。那段东西
    /// 在清单的步骤行里给一次就够了，日志行和结论条再各印一遍，真正的错因会被淹掉。
    private nonisolated static func firstParagraph(_ text: String) -> String {
        text.components(separatedBy: "\n\n").first ?? text
    }

    private func stepTitle(_ kind: SetupStep.Kind) -> String {
        setupChecklist.steps.first { $0.kind == kind }?.title ?? kind.rawValue
    }

    private func perform(_ kind: SetupStep.Kind) async -> SetupStepOutcome {
        switch kind {
        case .singBox: await installSingBox()
        case .directories: await createDirectoriesForAutomation()
        case .launchAgent: await installLaunchAgentForAutomation()
        // 订阅地址只能用户给，上面的 `manualReason` 已经拦下，这里只是把分支补全。
        case .subscription: .skipped("需要你自己完成。")
        // 同理：写 Surge 配置那种模式也已被拦下，能走到这里的只有「输出订阅地址」，
        // 而那条路要做的就是把本地服务拉起来。
        case .output: await startLocalSubscriptionService()
        case .service: await startSingBoxForAutomation()
        case .autoLaunch: enableLaunchAtLoginForAutomation()
        }
    }

    private func installSingBox() async -> SetupStepOutcome {
        // 进度同时送两个地方：清单上那行实时状态（回答「还活着吗」），
        // 以及日志页（事后排查时要能回看完整过程）。
        let installer = SingBoxInstaller { progress in
            Task { @MainActor [weak self] in
                self?.reportSetupProgress(progress.message, fraction: progress.fraction)
                // 下载那一路每个百分点报一条，全写进日志会把其它记录冲掉；
                // 带百分比的只更新界面，日志只留没有百分比的那些阶段性事件。
                if progress.fraction == nil {
                    RuntimeLog.shared.info("引导", progress.message)
                }
            }
        }
        do {
            let installed = try await installer.install()
            var updated = settings
            updated.singBoxBinaryPath = installed.binaryPath
            if updated == settings {
                // 装到的正是设置里已有的那条路径，不必重存；但自检结果得重算一次，
                // 否则界面还停在「未找到」，看着像没生效。
                await refreshServiceAsync()
            } else {
                await saveSettingsAsync(updated)
            }
            return .done("经 \(installed.method.label) 安装 \(installed.version)：\(installed.binaryPath)")
        } catch {
            // 走到这里意味着 brew 和 GitHub 两条路都没成。光报错等于把人扔在死路上——
            // 而「没有 brew 又到不了 GitHub」恰恰是这个应用最典型的处境，所以把手工
            // 出路一并给出来，让他能照着敲完。
            return .failed("\(error.localizedDescription)\n\n\(SetupChecklist.manualInstallGuide)")
        }
    }

    private func createDirectoriesForAutomation() async -> SetupStepOutcome {
        let errors = apply(await coordinator.createRequiredDirectories())
        guard errors.isEmpty else { return .failed(errors.joined(separator: "；")) }
        return .done("已创建 \(runtimePaths.singBoxConfigDirectory.path)")
    }

    private func installLaunchAgentForAutomation() async -> SetupStepOutcome {
        switch await coordinator.launchAgentState() {
        case .managedUpToDate:
            return .done("plist 已是最新（\(settings.launchAgentLabel)）")
        case .foreign:
            // 用户手写的 plist 里可能有 RouteBar 不认识的字段（代理环境变量、Nice 值、
            // 资源限制），静默覆盖等于悄悄改掉他的服务配置——这一步只能他自己点头。
            return .skipped("\(runtimePaths.launchAgent.path) 不是 RouteBar 创建的。"
                + "去「环境」页看过完整内容再决定要不要覆盖。")
        case .missing, .managedOutdated:
            let errors = apply(await coordinator.installLaunchAgent(allowOverwritingForeignFile: false))
            await refreshLogs()
            guard errors.isEmpty else { return .failed(errors.joined(separator: "；")) }
            return .done("已生成 plist 并交给 launchd（\(settings.launchAgentLabel)）")
        }
    }

    private func startLocalSubscriptionService() async -> SetupStepOutcome {
        await syncServer()
        guard subscriptionServing else {
            return .failed(subscriptionError
                ?? "本地订阅端口没能监听，通常是被别的程序占用了，见「服务」页。")
        }
        return .done("已在监听，订阅地址：\(subscriptionURL)")
    }

    private func startSingBoxForAutomation() async -> SetupStepOutcome {
        // 没有启用节点时配置里一个出口都没有，这时把服务拉起来只会得到一个反复退出的
        // launchd 任务，报出来的错跟真正的故障长得一样。等节点到位后，添加订阅那条
        // 路径自己会生成配置并重启服务，不必在这里硬启。
        guard enabledNodeCount > 0 else {
            return .skipped(subscriptions.isEmpty
                ? "还没有订阅，配置里没有任何出口。添加订阅后 RouteBar 会自动生成配置并启动。"
                : "当前没有启用的节点，生成出来的配置会是空的。先去「节点」页启用几个。")
        }
        apply(await coordinator.regenerate(forceRestart: true))
        await refreshLogs()
        guard serviceState.isRunning else {
            return .failed(serviceState.failureReason ?? "sing-box 没能起来，见「服务」页的错误日志。")
        }
        return .done("sing-box 正在运行，\(enabledNodeCount) 个节点已有本机端口")
    }

    private func enableLaunchAtLoginForAutomation() -> SetupStepOutcome {
        setLaunchAtLogin(true)
        switch loginItemState {
        case .enabled:
            return .done("已设为登录时启动")
        case .requiresApproval:
            // 注册确实生效了，只是系统要用户批准一次，这不是失败。
            return .skipped("已注册，但需要你在「系统设置 → 通用 → 登录项」里批准一次。")
        case .disabled:
            return .failed("注册之后系统仍报告未启用。从 Xcode 直接跑时会这样，装进「应用程序」再试。")
        case .failed(let reason):
            return .failed(reason)
        }
    }

    /// 收尾结论。
    ///
    /// 「失败」和「还得你自己做」必须分开报：前者要用户去查日志，后者只要他动一下手。
    /// 混成一句「还有 3 步未完成」，两种情况的下一步动作完全不同却看不出来。
    private func makeSetupReport() -> SetupAutomationRun.Report {
        let checklist = setupChecklist
        var failed: [String] = []
        var pending: [String] = []
        // 按清单顺序收集而不是遍历字典：字典无序，同一次运行两次渲染出的顺序会不一样。
        for step in checklist.steps {
            switch setupRun.outcomes[step.kind] {
            case .failed(let text): failed.append("\(step.title)：\(Self.firstParagraph(text))")
            case .skipped(let text) where !step.isDone: pending.append("\(step.title)：\(text)")
            default: break
            }
        }

        if !failed.isEmpty {
            return .init(verdict: .failed,
                         headline: "有 \(failed.count) 步没能做完，其余都已就位。",
                         remaining: failed + pending)
        }
        if !checklist.isComplete {
            return .init(verdict: .needsYou,
                         headline: "RouteBar 这边已经就位，还差 \(checklist.remainingRequiredCount) 步只能你自己做。",
                         remaining: pending)
        }
        return .init(verdict: .ready,
                     headline: pending.isEmpty ? "全部配好了，可以用了。" : "必需项全部完成，还有几条建议项。",
                     remaining: pending)
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
            url = try await coordinator.subscriptionURL(for: existingID)
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

    /// 全局模板与命名方式走设置：它们和端口、输出方式一样是应用级配置，存在 settings.json 里。
    func apiSetNaming(_ input: APINamingInput) async {
        var updated = settings
        updated.nodeNameTemplate = NodeNaming.normalized(input.template)
        // 请求里没带方式时保持原样——老网页只发 template，不该顺手把方式改掉。
        if let style = input.namingStyle { updated.nodeNamingStyle = style }
        await saveSettingsAsync(updated)
    }

    /// 地区表整张替换。清洗过再存：空地区名或空关键词会让那条规则匹配所有名字，
    /// 把它后面的规则全部挡死，而表面上只是「怎么所有节点都算香港」。
    func apiSetRegionRules(_ rules: [RegionRule]) async {
        var updated = settings
        let cleaned = NodeNormalization.normalized(rules)
        updated.regionRules = cleaned.isEmpty ? NodeNormalization.defaultRegionRules : cleaned
        await saveSettingsAsync(updated)
    }

    func apiPreviewNodeNames(_ input: APINamingInput) async -> APINamingPreview {
        APINamingPreview(state: currentViewState, template: input.template,
                         style: input.namingStyle, regionRules: input.regionRules)
    }

    func apiDeleteSubscription(_ id: UUID) async { await deleteSubscription(id) }
    func apiSetSubscriptionEnabled(_ enabled: Bool, id: UUID) async { await applySubscriptionEnabled(enabled, id: id) }
    func apiUpdateSubscription(_ id: UUID) async { await update(id) }
    func apiUpdateAll() async { await updateAll() }
    func apiSetNodeEnabled(_ enabled: Bool, id: String) async { await applyNodeEnabled(enabled, id: id) }
    func apiTestNode(_ id: String) async {
        guard let item = displayedNodes.first(where: { $0.id == id }), item.effectiveEnabled else { return }
        await testNode(item.id)
    }
    func apiTestAllNodes() async { await testAllNodes() }

    func apiProbeGeoAll() async { await probeGeoForAllNodes() }

    func apiProbeGeo(_ id: String) async {
        guard let item = displayedNodes.first(where: { $0.id == id }), item.effectiveEnabled else { return }
        await probeGeo(item.id)
    }

    /// 网络测试页：对一个目标逐节点测可达性。
    ///
    /// 目标地址由用户当场填，必须在这里校验协议——不校验的话，一个 `file://`
    /// 会让 URLSession 去读本机文件，而这个接口是网页可以调的。
    func apiProbeTargets(url: String, ids: [String]?) async throws -> APIProbeResponse {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = URL(string: trimmed), let scheme = target.scheme?.lowercased(),
              scheme == "http" || scheme == "https", target.host != nil else {
            throw APIInputError.invalidProbeURL
        }
        guard serviceState.isRunning else { throw APIInputError.serviceNotRunning }

        let all = await coordinator.mappedNodes()
        let wanted = ids.map(Set.init)
        let mapped = wanted.map { set in all.filter { set.contains($0.node.entryID) } } ?? all
        guard !mapped.isEmpty else { throw APIInputError.noNodesToProbe }

        let records = await coordinator.probeTargets(mapped, url: target)
        // 按耗时排序：这一页要回答的是「哪个节点到得了、哪个最快」，
        // 按节点名排的话得自己在几十行里找。到不了的沉到底部。
        let results = mapped.compactMap { item -> APIProbeResult? in
            guard let record = records[item.node.entryID] else { return nil }
            return APIProbeResult(id: item.node.entryID, name: item.node.name,
                                  localPort: item.localPort, record: record, geo: item.node.geo)
        }.sorted { lhs, rhs in
            if lhs.ok != rhs.ok { return lhs.ok }
            return (lhs.milliseconds ?? .max) < (rhs.milliseconds ?? .max)
        }
        return APIProbeResponse(url: trimmed, results: results)
    }
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
        case invalidProbeURL
        case serviceNotRunning
        case noNodesToProbe

        var errorDescription: String? {
            switch self {
            case .missingURL: "缺少订阅地址"
            case .invalidURL: "订阅地址必须是 http 或 https 链接"
            case .invalidProbeURL: "测试目标必须是带主机名的 http 或 https 地址"
            case .serviceNotRunning: "sing-box 未在运行，测试要经过本地端口，请先启动服务"
            case .noNodesToProbe: "没有可测试的启用节点"
            }
        }
    }
}
