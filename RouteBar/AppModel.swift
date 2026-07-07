import Foundation
import Combine
import AppKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var subscriptions: [SubscriptionRecord]
    @Published var selectedSubscriptionID: UUID?
    @Published var searchText = ""
    @Published var isUpdating = false
    @Published var updateProgress = 0.0
    @Published var serviceState: ServiceState
    @Published var alertMessage: String?
    @Published var autoUpdatePaused = false
    @Published var nextUpdateDate: Date?
    @Published var testingNodeIDs: Set<String> = []
    @Published var singBoxLogText = ""
    @Published var singBoxErrorLogText = ""
    @Published var updateLogText = ""
    @Published var settings: RouteBarSettings
    @Published var showingSetup = false

    private let keychain = KeychainStore()
    private let stateStore = StateStore()
    private var runtime: RuntimeManager
    private let latencyTester = LatencyTester()
    private var schedulerTask: Task<Void, Never>?

    init() {
        let loadedSettings = stateStore.loadSettings()
        let loadedState = stateStore.load()
        settings = loadedSettings
        runtime = RuntimeManager(settings: loadedSettings)
        #if DEBUG
        let loaded = ProcessInfo.processInfo.environment["ROUTEBAR_SNAPSHOT"] == "1"
            ? SubscriptionRecord.previewData : loadedState.subscriptions
        #else
        let loaded = loadedState.subscriptions
        #endif
        subscriptions = loaded
        selectedSubscriptionID = nil
        serviceState = runtime.status()
        autoUpdatePaused = loadedState.autoUpdatePaused
        updateLogText = stateStore.loadUpdateLog()
    }

    var runtimePaths: RuntimePaths { runtime.paths }
    var environmentReport: RouteBarEnvironmentReport {
        RouteBarEnvironmentReport(paths: runtimePaths) { FileManager.default.fileExists(atPath: $0.path) }
    }

    var selectedSubscription: SubscriptionRecord? {
        subscriptions.first { $0.id == selectedSubscriptionID }
    }

    var filteredSubscriptions: [SubscriptionRecord] {
        guard !searchText.isEmpty else { return subscriptions }
        return subscriptions.filter { $0.name.localizedCaseInsensitiveContains(searchText) || $0.note.localizedCaseInsensitiveContains(searchText) }
    }

    var mergedNodes: [ProxyNode] {
        NodeCatalog.merge(subscriptions.filter(\.isEnabled).flatMap(\.nodes))
    }

    var rawNodeCount: Int { subscriptions.reduce(0) { $0 + $1.nodes.count } }
    var deduplicatedCount: Int { max(0, rawNodeCount - mergedNodes.count) }
    var deduplicationRate: Double { rawNodeCount == 0 ? 0 : Double(deduplicatedCount) / Double(rawNodeCount) }
    var summary: RouteBarSummary { RouteBarSummary(subscriptions: subscriptions) }
    var healthMessages: [String] {
        var messages: [String] = []
        if subscriptions.isEmpty { messages.append("还没有订阅，先添加一个订阅地址。") }
        if summary.failedSubscriptions > 0 { messages.append("\(summary.failedSubscriptions) 个订阅最近更新失败。") }
        if summary.enabledSubscriptions > 0 && summary.enabledNodes == 0 { messages.append("当前没有启用节点，Surge 分流会缺少可选代理。") }
        if environmentReport.singBoxBinary == .missing { messages.append("未找到 sing-box 可执行文件，请在环境设置中确认路径。") }
        if !runtimePathExists(runtimePaths.launchAgent) { messages.append("LaunchAgent 未找到，sing-box 可能无法由 RouteBar 管理。") }
        if !runtimePathExists(runtimePaths.surgeProfile) { messages.append("Surge 托管配置未找到，需要先生成或确认配置路径。") }
        if case .failed(let reason) = serviceState { messages.append("sing-box 状态异常：\(reason)") }
        return messages
    }

    func bootstrap() async {
        showingSetup = environmentReport.needsSetup
        if subscriptions.isEmpty { importExistingSubscription() }
        if subscriptions.contains(where: { $0.nodes.isEmpty && $0.isEnabled }) { await updateAll() }
        refreshServiceState()
        refreshRuntimeArtifacts()
        startScheduler()
    }

    func url(for subscription: SubscriptionRecord) -> String { keychain.value(for: subscription.id) ?? "" }

    func saveSubscription(id: UUID?, name: String, url: String, note: String, interval: Int) {
        let recordID = id ?? UUID()
        do {
            try keychain.set(url, for: recordID)
            if let index = subscriptions.firstIndex(where: { $0.id == recordID }) {
                subscriptions[index].name = name; subscriptions[index].note = note
                subscriptions[index].updateIntervalHours = interval
            } else {
                subscriptions.append(SubscriptionRecord(id: recordID, name: name, note: note, updateIntervalHours: interval))
            }
            selectedSubscriptionID = recordID
            persist()
        } catch { alertMessage = error.localizedDescription }
    }

    func delete(_ subscription: SubscriptionRecord) {
        keychain.remove(subscription.id)
        subscriptions.removeAll { $0.id == subscription.id }
        selectedSubscriptionID = nil
        persist()
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard let index = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        subscriptions[index].isEnabled = enabled
        subscriptions[index].status = enabled ? .idle : .disabled
        persist(); regenerate()
    }

    func updateAll() async {
        guard !isUpdating else { return }
        appendUpdateLog("开始更新全部启用订阅")
        isUpdating = true; updateProgress = 0
        let enabledIDs = subscriptions.filter(\.isEnabled).map(\.id)
        for (offset, id) in enabledIDs.enumerated() {
            await update(id)
            updateProgress = Double(offset + 1) / Double(max(enabledIDs.count, 1))
        }
        regenerate()
        appendUpdateLog("全部更新流程结束，已重新生成配置")
        isUpdating = false
    }

    func update(_ id: UUID) async {
        guard let index = subscriptions.firstIndex(where: { $0.id == id }),
              let value = keychain.value(for: id), let url = URL(string: value) else { return }
        let name = subscriptions[index].name
        appendUpdateLog("开始更新订阅：\(name)")
        subscriptions[index].status = .updating
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { throw URLError(.badServerResponse) }
            let parsed = try VLESSParser.parseSubscription(data, sourceID: id)
            guard !parsed.isEmpty else { throw SubscriptionError.empty }
            subscriptions[index].nodes = NodeCatalog.carryPersistedState(from: subscriptions[index].nodes, to: parsed)
            subscriptions[index].updatedAt = .now
            subscriptions[index].status = .success; subscriptions[index].lastError = nil
            appendUpdateLog("更新成功：\(name)，解析到 \(parsed.count) 个节点")
        } catch {
            subscriptions[index].status = .failed; subscriptions[index].lastError = error.localizedDescription
            appendUpdateLog("更新失败：\(name)，\(error.localizedDescription)")
        }
        persist()
    }

    func restartService() { serviceState = runtime.restart() }
    func stopService() { serviceState = runtime.stop() }
    func refreshServiceState() { serviceState = runtime.status() }
    func refreshRuntimeArtifacts() {
        refreshServiceState()
        singBoxLogText = tail(runtimePaths.singBoxLog)
        singBoxErrorLogText = tail(runtimePaths.singBoxErrorLog)
        updateLogText = stateStore.loadUpdateLog()
    }

    func runtimePathExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func openRuntimePath(_ url: URL) {
        if runtimePathExists(url) {
            NSWorkspace.shared.open(url)
        } else {
            alertMessage = "文件不存在：\(url.path)"
        }
    }

    func revealRuntimePath(_ url: URL) {
        if runtimePathExists(url) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    func copyRuntimePath(_ url: URL) {
        copyText(url.path)
    }

    func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func saveSettings(_ newSettings: RouteBarSettings) {
        do {
            try stateStore.saveSettings(newSettings)
            settings = newSettings
            runtime = RuntimeManager(settings: newSettings)
            refreshRuntimeArtifacts()
            showingSetup = environmentReport.needsSetup
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func createRequiredDirectories() {
        do {
            try FileManager.default.createDirectory(at: runtimePaths.singBoxConfigDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: runtimePaths.launchAgent.deletingLastPathComponent(), withIntermediateDirectories: true)
            showingSetup = environmentReport.needsSetup
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func setNodeEnabled(_ enabled: Bool, id: String) {
        for subscriptionIndex in subscriptions.indices {
            for nodeIndex in subscriptions[subscriptionIndex].nodes.indices
            where subscriptions[subscriptionIndex].nodes[nodeIndex].id == id {
                subscriptions[subscriptionIndex].nodes[nodeIndex].isEnabled = enabled
            }
        }
        persist(); regenerate()
    }

    func testAllNodes() async {
        guard !mergedNodes.isEmpty else { return }
        do {
            let mapped = try ConfigurationGenerator.generate(nodes: mergedNodes).nodes
            testingNodeIDs.formUnion(mapped.map(\.node.id))
            let results = await latencyTester.test(mapped)
            applyLatency(results)
            testingNodeIDs.subtract(mapped.map(\.node.id))
        } catch { alertMessage = error.localizedDescription }
    }

    func testNode(_ id: String) async {
        do {
            guard let mapped = try ConfigurationGenerator.generate(nodes: mergedNodes).nodes.first(where: { $0.node.id == id }) else { return }
            testingNodeIDs.insert(id)
            let result = await latencyTester.test(mapped)
            applyLatency([result.0: result.1])
            testingNodeIDs.remove(id)
        } catch { alertMessage = error.localizedDescription }
    }

    func toggleAutoUpdate() {
        autoUpdatePaused.toggle()
        persist()
        recalculateNextUpdate()
    }

    func appBecameActive() {
        refreshRuntimeArtifacts()
        recalculateNextUpdate()
        Task { await runDueUpdates() }
    }

    private func startScheduler() {
        guard schedulerTask == nil else { return }
        recalculateNextUpdate()
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                let due = self.subscriptions.filter { UpdateSchedule.isDue($0, isPaused: self.autoUpdatePaused) }
                await self.runDueUpdates(due)
                self.recalculateNextUpdate()
            }
        }
    }

    private func runDueUpdates(_ due: [SubscriptionRecord]? = nil) async {
        let dueSubscriptions = due ?? subscriptions.filter { UpdateSchedule.isDue($0, isPaused: autoUpdatePaused) }
        guard !dueSubscriptions.isEmpty, !isUpdating else { return }
        isUpdating = true
        for (offset, subscription) in dueSubscriptions.enumerated() {
            await update(subscription.id)
            updateProgress = Double(offset + 1) / Double(max(dueSubscriptions.count, 1))
        }
        regenerate()
        appendUpdateLog("自动更新完成，已重新生成配置")
        isUpdating = false
    }

    private func recalculateNextUpdate() {
        guard !autoUpdatePaused else { nextUpdateDate = nil; return }
        nextUpdateDate = subscriptions.filter(\.isEnabled).compactMap { UpdateSchedule.nextUpdate(for: $0) ?? .now }.min()
    }

    private func tail(_ url: URL, limit: Int = 20_000) -> String {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return "暂无日志：\(url.path)" }
        let suffix = data.count > limit ? data.suffix(limit) : data[...]
        return String(decoding: suffix, as: UTF8.self)
    }

    private func applyLatency(_ results: [String: LatencyRecord]) {
        for subscriptionIndex in subscriptions.indices {
            for nodeIndex in subscriptions[subscriptionIndex].nodes.indices {
                let id = subscriptions[subscriptionIndex].nodes[nodeIndex].id
                if let latency = results[id] { subscriptions[subscriptionIndex].nodes[nodeIndex].latency = latency }
            }
        }
        persist()
    }

    private func regenerate() {
        do {
            let generated = try ConfigurationGenerator.generate(nodes: mergedNodes)
            try stateStore.saveGenerated(generated)
            try runtime.install(generated)
            serviceState = runtime.restart()
            appendUpdateLog("配置生成成功：\(generated.nodes.count) 个启用节点")
        }
        catch {
            alertMessage = error.localizedDescription
            appendUpdateLog("配置生成失败：\(error.localizedDescription)")
        }
    }

    private func appendUpdateLog(_ message: String) {
        let line = "[\(Date.now.formatted(date: .numeric, time: .standard))] \(message)"
        let current = stateStore.loadUpdateLog()
        let next = current.isEmpty ? line : "\(line)\n\(current)"
        updateLogText = next
        try? stateStore.saveUpdateLog(next)
    }

    private func persist() {
        do { try stateStore.save(RouteBarState(subscriptions: subscriptions, autoUpdatePaused: autoUpdatePaused)) }
        catch { alertMessage = error.localizedDescription }
    }

    private func importExistingSubscription() {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/mihomo/config.yaml")
        guard let text = try? String(contentsOf: path, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #"url:\s*\"([^\"]+)\""#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return }
        saveSubscription(id: nil, name: "当前订阅", url: String(text[range]), note: "从现有 Mihomo 配置导入", interval: 6)
    }

    enum SubscriptionError: LocalizedError {
        case empty
        var errorDescription: String? { "订阅中没有可用的 VLESS Reality 节点" }
    }
}

#if DEBUG
private extension SubscriptionRecord {
    static var previewData: [SubscriptionRecord] {
        let specs = [("机场主力", 18, true), ("备用机场", 12, true), ("家庭节点", 10, true),
                     ("测试订阅", 4, false), ("香港节点", 8, true), ("日本节点", 9, true)]
        return specs.enumerated().map { index, spec in
            let source = UUID()
            let nodes = (0..<spec.1).map { number in
                ProxyNode(id: "\(index)-\(number)", name: "节点 \(number + 1)",
                          server: "node\(number).example.com", serverPort: 443,
                          uuid: UUID().uuidString, flow: "xtls-rprx-vision",
                          serverName: "www.apple.com", publicKey: "preview", shortID: "abcd",
                          fingerprint: "chrome", sourceIDs: [source], isEnabled: true,
                          latency: LatencyRecord(outcome: .success, milliseconds: 35 + ((index * 37 + number * 11) % 220), measuredAt: .now))
            }
            return SubscriptionRecord(id: source, name: spec.0, note: "https://sub.example.com/\(index + 1)",
                                      isEnabled: spec.2, createdAt: .now.addingTimeInterval(-86400 * 30),
                                      updatedAt: .now.addingTimeInterval(Double(-index * 1800)),
                                      status: spec.2 ? .success : .disabled, nodes: nodes)
        }
    }
}
#endif
