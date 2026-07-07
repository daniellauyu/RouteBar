import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case dashboard = "仪表盘", subscriptions = "订阅管理", nodes = "节点管理"
    case service = "服务管理", logs = "日志", settings = "设置"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.67percent"
        case .subscriptions: "square.3.layers.3d"
        case .nodes: "point.3.connected.trianglepath.dotted"
        case .service: "play.circle"
        case .logs: "doc.text"
        case .settings: "gearshape"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var section: AppSection? = ProcessInfo.processInfo.environment["ROUTEBAR_SNAPSHOT_SECTION"] == "nodes" ? .nodes : .dashboard
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn
    @State private var editor: EditorContext?
    @State private var selectedNodeID: String?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } content: {
            if section == .dashboard { DashboardView(section: $section) }
            else if section == .subscriptions { subscriptionContent }
            else if section == .nodes { NodeWorkspaceView(selectedNodeID: $selectedNodeID, revealDetail: { columnVisibility = .all }) }
            else if section == .service { ServiceManagementView() }
            else if section == .logs { LogsView() }
            else if section == .settings { SettingsView() }
            else { DashboardView(section: $section) }
        } detail: {
            if section == .dashboard { DashboardDetailView() }
            else if section == .subscriptions { inspector }
            else if section == .nodes { nodeInspector }
            else if section == .service { ServiceDetailView() }
            else if section == .logs { LogDetailView() }
            else if section == .settings { SettingsDetailView() }
            else { DashboardDetailView() }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1180, minHeight: 720)
        .onChange(of: section) { _, newSection in
            if newSection != .subscriptions && newSection != .nodes {
                columnVisibility = .doubleColumn
            }
        }
        .task { await model.bootstrap() }
        .sheet(item: $editor) { context in
            SubscriptionEditor(context: context) { id, name, url, note, interval in
                model.saveSubscription(id: id, name: name, url: url, note: note, interval: interval)
                Task { if let id { await model.update(id) } else { await model.updateAll() } }
            }
        }
        .sheet(isPresented: $model.showingSetup) {
            SetupAssistantView()
                .environmentObject(model)
        }
        .alert("RouteBar", isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) {
            Button("好") { model.alertMessage = nil }
        } message: { Text(model.alertMessage ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "paperplane.fill")
                    .font(.title2)
                Text("RouteBar")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 24)
            .padding(.bottom, 22)

            VStack(spacing: 4) {
                ForEach(AppSection.allCases) { item in
                    SidebarNavigationRow(item: item, isSelected: section == item) {
                        selectSection(item)
                    }
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 24)

            ServiceStatusPanel(title: serviceTitle,
                               subtitle: "sing-box 1.13",
                               color: serviceColor,
                               refresh: { model.refreshRuntimeArtifacts() },
                               openLogs: { selectSection(.logs) })
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
        }
        .background(.ultraThinMaterial)
        .navigationSplitViewColumnWidth(min: 188, ideal: 208, max: 232)
    }

    private var subscriptionContent: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索订阅名称或备注", text: $model.searchText).textFieldStyle(.plain)
            }
            .padding(.horizontal, 12).frame(height: 34)
            .background(.background, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(.separator.opacity(0.75)))
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            tableHeader
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.filteredSubscriptions) { subscription in
                        SubscriptionRow(subscription: subscription,
                                        isSelected: model.selectedSubscriptionID == subscription.id,
                                        onSelect: {
                                            model.selectedSubscriptionID = subscription.id
                                            columnVisibility = .all
                                        },
                                        onToggle: { model.setEnabled($0, for: subscription.id) })
                        Divider().padding(.leading, 16)
                    }
                }
            }
            Spacer(minLength: 0)
            footer
        }
        .navigationSplitViewColumnWidth(min: 620, ideal: 780)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        VStack(spacing: 14) {
                HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("订阅管理").font(.title2.bold())
                    Text("管理订阅源，生成 sing-box 本地出口并同步到 Surge。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { editor = EditorContext() } label: { Label("添加订阅", systemImage: "plus") }.fixedSize()
                Button { model.showingSetup = true } label: { Label("环境设置", systemImage: "wrench.and.screwdriver") }.fixedSize()
                Button { Task { await model.updateAll() } } label: { Label("更新全部", systemImage: "arrow.clockwise") }.fixedSize()
                    .disabled(model.isUpdating)
                Menu {
                    Button("重新生成配置") { Task { await model.updateAll() } }
                    Divider()
                    Button("刷新服务状态") { model.refreshServiceState() }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
            HStack(spacing: 10) {
                SummaryMetric(value: "\(model.subscriptions.count)", label: "订阅")
                SummaryMetric(value: model.rawNodeCount.formatted(), label: "总节点")
                SummaryMetric(value: model.deduplicatedCount.formatted(), label: "去重后")
                SummaryMetric(value: model.deduplicationRate.formatted(.percent.precision(.fractionLength(1))), label: "去重率", tint: .green)
                Spacer()
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private var tableHeader: some View {
        HStack {
            Text("启用").frame(width: 55, alignment: .leading)
            Text("订阅名称").frame(maxWidth: .infinity, alignment: .leading)
            Text("节点数").frame(width: 105, alignment: .leading)
            Text("更新时间").frame(width: 130, alignment: .leading)
            Text("状态").frame(width: 105, alignment: .leading)
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).frame(height: 30)
    }

    private var footer: some View {
        HStack {
            Text(model.selectedSubscription == nil ? "未选择" : "已选择 1 项")
            Spacer()
            if model.isUpdating {
                ProgressView(value: model.updateProgress).frame(width: 130)
                Text("正在更新 \(Int(model.updateProgress * 100))%")
            }
            Spacer()
            Label("合并: \(model.rawNodeCount.formatted())", systemImage: "square.3.layers.3d")
            Label("去重: \(model.mergedNodes.count.formatted())", systemImage: "checkmark.shield")
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).frame(height: 38).background(.bar)
    }

    @ViewBuilder private var inspector: some View {
        if let subscription = model.selectedSubscription {
            SubscriptionInspector(subscription: subscription, url: model.url(for: subscription),
                                  edit: { editor = EditorContext(subscription: subscription, url: model.url(for: subscription)) },
                                  update: { Task { await model.update(subscription.id) } },
                                  delete: { model.delete(subscription) })
        } else {
            ContentUnavailableView("选择一个订阅", systemImage: "square.3.layers.3d", description: Text("查看详细信息和更新状态"))
        }
    }

    @ViewBuilder private var nodeInspector: some View {
        if let id = selectedNodeID, let node = model.mergedNodes.first(where: { $0.id == id }) {
            NodeInspectorView(node: node,
                              sources: model.subscriptions.filter { node.sourceIDs.contains($0.id) }.map(\.name),
                              isTesting: model.testingNodeIDs.contains(id),
                              test: { Task { await model.testNode(id) } },
                              toggle: { model.setNodeEnabled($0, id: id) })
        } else {
            ContentUnavailableView("选择一个节点", systemImage: "point.3.connected.trianglepath.dotted", description: Text("查看 Reality 参数和测速结果"))
        }
    }

    private var serviceTitle: String { if case .running = model.serviceState { "服务运行中" } else { "服务已停止" } }
    private var serviceColor: Color { if case .running = model.serviceState { .green } else { .secondary } }

    private func selectSection(_ item: AppSection) {
        section = item
        columnVisibility = .doubleColumn
        if item == .subscriptions { model.selectedSubscriptionID = nil }
        if item == .nodes { selectedNodeID = nil }
    }
}

private struct SummaryMetric: View {
    let value: String; let label: String; var tint: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline).monospacedDigit().foregroundStyle(tint)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 82, alignment: .leading)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct SidebarNavigationRow: View {
    let item: AppSection
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 22)
                Text(item.rawValue)
                    .font(.callout.weight(.semibold))
                Spacer()
            }
            .foregroundStyle(isSelected ? .white : .primary)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(isSelected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }
}

private struct ServiceStatusPanel: View {
    let title: String
    let subtitle: String
    let color: Color
    let refresh: () -> Void
    let openLogs: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 9) {
                Circle().fill(color).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack {
                Button(action: openLogs) { Image(systemName: "terminal") }
                    .help("查看日志")
                Spacer()
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                    .help("刷新状态")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.45)))
    }
}

private struct InspectorCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 13))
    }
}

private struct InspectorRow<Value: View>: View {
    let title: String
    @ViewBuilder var value: Value

    init(_ title: String, @ViewBuilder value: () -> Value) {
        self.title = title
        self.value = value()
    }

    init(_ title: String, _ value: String) where Value == Text {
        self.title = title
        self.value = Text(value)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 16)
            value
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .frame(minHeight: 40)
    }
}

private struct InspectorDivider: View {
    var body: some View {
        Divider().opacity(0.65)
    }
}

private struct SubscriptionRow: View {
    let subscription: SubscriptionRecord; let isSelected: Bool
    let onSelect: () -> Void; let onToggle: (Bool) -> Void
    var body: some View {
        HStack {
            Toggle("", isOn: Binding(get: { subscription.isEnabled }, set: onToggle)).labelsHidden().frame(width: 55, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                HStack { Text(subscription.name).fontWeight(.medium); if subscription.createdAt.timeIntervalSinceNow > -300 { Text("新增").font(.caption2).foregroundStyle(.blue).padding(.horizontal, 6).padding(.vertical, 2).background(.blue.opacity(0.12), in: Capsule()) } }
                Text(subscription.note.isEmpty ? "安全存储的订阅地址" : subscription.note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading) { Text(subscription.nodes.count.formatted()); Text("去重后 \(subscription.nodes.count)").font(.caption).foregroundStyle(.secondary) }.frame(width: 105, alignment: .leading)
            VStack(alignment: .leading) { Text(subscription.updatedAt?.formatted(date: .omitted, time: .shortened) ?? "尚未更新"); Text(relativeDate).font(.caption).foregroundStyle(.secondary) }.frame(width: 130, alignment: .leading)
            Label(statusText, systemImage: statusIcon).font(.callout).foregroundStyle(statusColor).frame(width: 105, alignment: .leading)
        }.padding(.horizontal, 18).frame(height: 64)
        .background(isSelected ? Color.accentColor.opacity(0.10) : .clear)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? Color.accentColor.opacity(0.55) : .clear).padding(4))
        .contentShape(Rectangle()).onTapGesture(perform: onSelect)
    }
    private var relativeDate: String {
        guard let date = subscription.updatedAt else { return "—" }
        let seconds = max(0, Int(-date.timeIntervalSinceNow))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前" }
        if seconds < 86400 { return "\(seconds / 3600) 小时前" }
        return "\(seconds / 86400) 天前"
    }
    private var statusText: String { switch subscription.status { case .success: "更新成功"; case .updating: "更新中"; case .failed: "更新失败"; case .disabled: "已禁用"; case .idle: "待更新" } }
    private var statusIcon: String { switch subscription.status { case .success: "checkmark.circle.fill"; case .updating: "arrow.triangle.2.circlepath"; case .failed: "exclamationmark.circle.fill"; case .disabled: "minus.circle.fill"; case .idle: "clock" } }
    private var statusColor: Color { switch subscription.status { case .success: .green; case .failed: .red; case .updating: .blue; default: .secondary } }
}

private struct SubscriptionInspector: View {
    let subscription: SubscriptionRecord; let url: String
    let edit: () -> Void; let update: () -> Void; let delete: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("订阅详情")
                    .font(.headline)
                    .padding(.top, 18)

                InspectorCard {
                    InspectorRow("订阅名称", subscription.name)
                    InspectorDivider()
                    InspectorRow("订阅地址", maskedURL)
                    if !subscription.note.isEmpty {
                        InspectorDivider()
                        InspectorRow("备注", subscription.note)
                    }
                }

                Text("安全状态").font(.headline)
                InspectorCard {
                    InspectorRow("凭据存储") {
                        Label("Keychain", systemImage: "lock.fill").foregroundStyle(.green)
                    }
                    InspectorDivider()
                    InspectorRow("连接", url.hasPrefix("https://") ? "HTTPS" : "需注意")
                }

                Text("订阅统计").font(.headline)
                InspectorCard {
                    InspectorRow("节点数", subscription.nodes.count.formatted())
                    InspectorDivider()
                    InspectorRow("最后更新时间", subscription.updatedAt?.formatted(date: .numeric, time: .shortened) ?? "尚未更新")
                    InspectorDivider()
                    InspectorRow("更新间隔", "\(subscription.updateIntervalHours) 小时")
                }

                if let error = subscription.lastError {
                    Text("最近错误").font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }

                HStack(spacing: 8) {
                    Button("立即更新", systemImage: "arrow.clockwise", action: update)
                    Button("编辑订阅", systemImage: "pencil", action: edit)
                    Button("删除", role: .destructive, action: delete)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .padding(.top, 2)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationSplitViewColumnWidth(min: 300, ideal: 330, max: 360)
    }
    private var maskedURL: String { guard let host = URL(string: url)?.host else { return "已安全存储" }; return "https://\(host)/••••••" }
}

private enum NodeLatencyFilter: String, CaseIterable, Identifiable {
    case all = "全部延迟", fast = "低于 100 ms", medium = "100–200 ms", slow = "高于 200 ms", failed = "不可用"
    var id: String { rawValue }
}

private enum NodeSort: String, CaseIterable, Identifiable {
    case name = "名称", latency = "延迟", source = "来源"
    var id: String { rawValue }
}

private struct NodeWorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selectedNodeID: String?
    let revealDetail: () -> Void
    @State private var searchText = ""
    @State private var sourceID: UUID?
    @State private var region = "全部地区"
    @State private var latencyFilter: NodeLatencyFilter = .all
    @State private var sort: NodeSort = .name

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("节点管理").font(.title2.bold()).fixedSize()
                Spacer()
                TextField("搜索节点", text: $searchText).textFieldStyle(.roundedBorder).frame(width: 180)
                Picker("订阅", selection: $sourceID) {
                    Text("全部订阅").tag(UUID?.none)
                    ForEach(model.subscriptions) { Text($0.name).tag(Optional($0.id)) }
                }.labelsHidden().frame(width: 125)
                Picker("地区", selection: $region) { ForEach(regions, id: \.self) { Text($0).tag($0) } }
                    .labelsHidden().frame(width: 110)
                Picker("延迟", selection: $latencyFilter) { ForEach(NodeLatencyFilter.allCases) { Text($0.rawValue).tag($0) } }
                    .labelsHidden().frame(width: 135)
                Menu { Picker("排序", selection: $sort) { ForEach(NodeSort.allCases) { Text($0.rawValue).tag($0) } } } label: { Label("排序", systemImage: "arrow.up.arrow.down") }
                Button { Task { await model.testAllNodes() } } label: { Label("测试全部", systemImage: "speedometer") }
                    .fixedSize().disabled(!model.testingNodeIDs.isEmpty)
            }.buttonStyle(.bordered).controlSize(.regular).padding(12)
            Divider()
            HStack {
                Text("状态").frame(width: 48, alignment: .leading)
                Text("节点名称").frame(maxWidth: .infinity, alignment: .leading)
                Text("来源订阅").frame(width: 130, alignment: .leading)
                Text("协议").frame(width: 70, alignment: .leading)
                Text("本地端口").frame(width: 80, alignment: .leading)
                Text("延迟").frame(width: 90, alignment: .leading)
                Text("启用").frame(width: 50, alignment: .leading)
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).frame(height: 36)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredNodes, id: \.node.id) { item in
                        NodeRow(node: item.node, port: item.localPort, source: sourceName(for: item.node),
                                isSelected: selectedNodeID == item.node.id,
                                isTesting: model.testingNodeIDs.contains(item.node.id),
                                select: {
                                    selectedNodeID = item.node.id
                                    revealDetail()
                                },
                                toggle: { model.setNodeEnabled($0, id: item.node.id) })
                        Divider().padding(.leading, 14)
                    }
                }
            }
            Spacer(minLength: 0)
            HStack { Text("显示 \(filteredNodes.count) / \(mappedNodes.count) 个启用节点"); Spacer(); if !model.testingNodeIDs.isEmpty { ProgressView(); Text("正在测速 \(model.testingNodeIDs.count) 个节点") } }
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).frame(height: 40).background(.bar)
        }
        .navigationSplitViewColumnWidth(min: 700, ideal: 820)
    }

    private var mappedNodes: [PortMappedNode] {
        (try? ConfigurationGenerator.generate(nodes: model.mergedNodes).nodes) ?? []
    }

    private var filteredNodes: [PortMappedNode] {
        mappedNodes.filter { item in
            let node = item.node
            return (searchText.isEmpty || node.name.localizedCaseInsensitiveContains(searchText) || node.server.localizedCaseInsensitiveContains(searchText)) &&
            (sourceID == nil || node.sourceIDs.contains(sourceID!)) &&
            (region == "全部地区" || inferredRegion(node.name) == region) && matchesLatency(node)
        }.sorted { lhs, rhs in
            switch sort {
            case .name: lhs.node.name.localizedStandardCompare(rhs.node.name) == .orderedAscending
            case .source: sourceName(for: lhs.node).localizedStandardCompare(sourceName(for: rhs.node)) == .orderedAscending
            case .latency: (lhs.node.latency?.milliseconds ?? Int.max) < (rhs.node.latency?.milliseconds ?? Int.max)
            }
        }
    }

    private var regions: [String] { ["全部地区"] + Array(Set(mappedNodes.map { inferredRegion($0.node.name) })).sorted() }
    private func sourceName(for node: ProxyNode) -> String { model.subscriptions.first { node.sourceIDs.contains($0.id) }?.name ?? "未知" }
    private func matchesLatency(_ node: ProxyNode) -> Bool {
        switch latencyFilter {
        case .all: true
        case .fast: (node.latency?.milliseconds ?? Int.max) < 100
        case .medium: (100...200).contains(node.latency?.milliseconds ?? -1)
        case .slow: (node.latency?.milliseconds ?? -1) > 200
        case .failed: node.latency != nil && node.latency?.outcome != .success
        }
    }
}

private struct NodeRow: View {
    let node: ProxyNode; let port: Int; let source: String; let isSelected: Bool; let isTesting: Bool
    let select: () -> Void; let toggle: (Bool) -> Void
    var body: some View {
        HStack {
            Group { if isTesting { ProgressView().controlSize(.small) } else { Circle().fill(statusColor).frame(width: 9, height: 9) } }.frame(width: 48, alignment: .leading)
            Text(node.name).font(.callout.weight(.medium)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(source).font(.callout).lineLimit(1).frame(width: 130, alignment: .leading)
            Text("VLESS").font(.callout).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(port.formatted()).font(.callout).monospacedDigit().frame(width: 80, alignment: .leading)
            Text(latencyText).font(.callout).monospacedDigit().foregroundStyle(latencyColor).frame(width: 90, alignment: .leading)
            Toggle("", isOn: Binding(get: { node.isEnabled }, set: toggle)).labelsHidden().frame(width: 50, alignment: .leading)
        }.padding(.horizontal, 14).frame(height: 36)
        .background(isSelected ? Color.accentColor.opacity(0.10) : .clear)
        .contentShape(Rectangle()).onTapGesture(perform: select)
    }
    private var statusColor: Color { node.latency?.outcome == .success ? .green : node.latency == nil ? .secondary : .red }
    private var latencyText: String { if let value = node.latency?.milliseconds { "\(value) ms" } else if node.latency != nil { "失败" } else { "未测试" } }
    private var latencyColor: Color { guard let value = node.latency?.milliseconds else { return .secondary }; return value < 100 ? .green : value <= 200 ? .orange : .red }
}

private struct NodeInspectorView: View {
    let node: ProxyNode; let sources: [String]; let isTesting: Bool
    let test: () -> Void; let toggle: (Bool) -> Void
    var body: some View {
        Form {
            Section("节点详情") { LabeledContent("节点名称", value: node.name); LabeledContent("状态", value: node.isEnabled ? "已启用" : "已禁用"); LabeledContent("来源", value: sources.joined(separator: "、")) }
            Section("服务器") { LabeledContent("地址", value: node.server); LabeledContent("端口", value: node.serverPort.formatted()); LabeledContent("协议", value: "VLESS"); LabeledContent("传输", value: "TCP") }
            Section("Reality") { LabeledContent("流控", value: node.flow); LabeledContent("SNI", value: node.serverName); LabeledContent("指纹", value: node.fingerprint); LabeledContent("Short ID", value: node.shortID.isEmpty ? "—" : node.shortID) }
            Section("延迟") { LabeledContent("结果", value: latencyDescription); if let date = node.latency?.measuredAt { LabeledContent("测试时间", value: date.formatted()) } }
            Section { HStack { Button("测试延迟", systemImage: "speedometer", action: test).disabled(isTesting); Toggle("启用节点", isOn: Binding(get: { node.isEnabled }, set: toggle)) } }
        }.formStyle(.grouped).navigationTitle("节点详情").navigationSplitViewColumnWidth(min: 300, ideal: 350)
    }
    private var latencyDescription: String { if isTesting { return "测试中" }; if let value = node.latency?.milliseconds { return "\(value) ms" }; return node.latency == nil ? "未测试" : "连接失败" }
}

private func inferredRegion(_ name: String) -> String {
    let pairs = [("香港", ["香港", "HK", "Hong Kong"]), ("日本", ["日本", "东京", "大阪", "JP", "Japan"]),
                 ("美国", ["美国", "洛杉矶", "US", "United States"]), ("新加坡", ["新加坡", "SG", "Singapore"]),
                 ("台湾", ["台湾", "台北", "TW", "Taiwan"]), ("韩国", ["韩国", "首尔", "KR", "Korea"])]
    return pairs.first { pair in pair.1.contains { name.localizedCaseInsensitiveContains($0) } }?.0 ?? "其他"
}

private struct ServiceManagementView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("服务管理").font(.title2.bold())
                Spacer()
                Button("刷新", systemImage: "arrow.clockwise") { model.refreshRuntimeArtifacts() }
                if case .running = model.serviceState {
                    Button("停止服务", systemImage: "stop.fill") { model.stopService() }
                } else {
                    Button("启动服务", systemImage: "play.fill") { model.restartService() }
                }
                Button("重启服务", systemImage: "restart") { model.restartService() }
            }
            .buttonStyle(.bordered).controlSize(.large).padding(18)
            Divider()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                RuntimeCard(title: "LaunchAgent", value: model.runtimePathExists(model.runtimePaths.launchAgent) ? "已安装" : "未找到", icon: "list.bullet.rectangle", tint: model.runtimePathExists(model.runtimePaths.launchAgent) ? .green : .orange)
                RuntimeCard(title: "sing-box 配置", value: model.runtimePathExists(model.runtimePaths.singBoxConfig) ? "已生成" : "未生成", icon: "curlybraces.square", tint: model.runtimePathExists(model.runtimePaths.singBoxConfig) ? .green : .orange)
                RuntimeCard(title: "Surge 配置", value: model.runtimePathExists(model.runtimePaths.surgeProfile) ? "已托管" : "未找到", icon: "network", tint: model.runtimePathExists(model.runtimePaths.surgeProfile) ? .green : .orange)
                RuntimeCard(title: "运行状态", value: serviceText, icon: "bolt.horizontal.circle", tint: serviceTint)
            }
            .padding(18)
            List {
                RuntimePathRow(title: "sing-box 配置", url: model.runtimePaths.singBoxConfig)
                RuntimePathRow(title: "标准日志", url: model.runtimePaths.singBoxLog)
                RuntimePathRow(title: "错误日志", url: model.runtimePaths.singBoxErrorLog)
                RuntimePathRow(title: "Surge 配置", url: model.runtimePaths.surgeProfile)
                RuntimePathRow(title: "LaunchAgent", url: model.runtimePaths.launchAgent)
            }
            .listStyle(.inset)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
        .onAppear { model.refreshRuntimeArtifacts() }
    }

    private var serviceText: String {
        switch model.serviceState { case .running: "运行中"; case .stopped: "已停止"; case .failed: "异常" }
    }
    private var serviceTint: Color {
        switch model.serviceState { case .running: .green; case .stopped: .secondary; case .failed: .red }
    }
}

private struct ServiceDetailView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        Form {
            Section("LaunchAgent") {
                LabeledContent("Label", value: model.runtimePaths.label)
                LabeledContent("Target", value: model.runtimePaths.launchctlTarget)
                LabeledContent("Plist", value: model.runtimePaths.launchAgent.path)
            }
            Section("操作说明") {
                Text("RouteBar 生成 sing-box 配置后会调用 launchctl 重启服务。若服务启动失败，先看错误日志，再运行 sing-box check。")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("打开 LaunchAgent", systemImage: "doc") { model.openRuntimePath(model.runtimePaths.launchAgent) }
                Button("定位配置目录", systemImage: "folder") { model.revealRuntimePath(model.runtimePaths.singBoxConfig) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("服务详情")
    }
}

private struct LogsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedLog = 0
    @State private var searchText = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("日志").font(.title2.bold())
                Spacer()
                TextField("过滤日志", text: $searchText).textFieldStyle(.roundedBorder).frame(width: 180)
                Picker("", selection: $selectedLog) {
                    Text("更新记录").tag(0)
                    Text("标准日志").tag(1)
                    Text("错误日志").tag(2)
                }
                    .pickerStyle(.segmented).frame(width: 260)
                Button("刷新", systemImage: "arrow.clockwise") { model.refreshRuntimeArtifacts() }
                Button("复制", systemImage: "doc.on.doc") { model.copyText(filteredText) }
                Button("打开日志", systemImage: "doc.text") { if let selectedURL { model.openRuntimePath(selectedURL) } }
                    .disabled(selectedURL == nil)
            }
            .buttonStyle(.bordered).controlSize(.large).padding(18)
            Divider()
            ScrollView {
                Text(filteredText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .onAppear { model.refreshRuntimeArtifacts() }
    }
    private var selectedText: String {
        switch selectedLog {
        case 0: model.updateLogText.isEmpty ? "暂无更新记录。本页会记录订阅更新、解析结果和配置生成结果。" : model.updateLogText
        case 1: model.singBoxLogText
        default: model.singBoxErrorLogText
        }
    }
    private var filteredText: String {
        guard !searchText.isEmpty else { return selectedText }
        let lines = selectedText.components(separatedBy: .newlines).filter { $0.localizedCaseInsensitiveContains(searchText) }
        return lines.isEmpty ? "没有匹配 “\(searchText)” 的日志行。" : lines.joined(separator: "\n")
    }
    private var selectedURL: URL? {
        switch selectedLog {
        case 0: model.runtimePaths.appSupportDirectory.appendingPathComponent("update.log")
        case 1: model.runtimePaths.singBoxLog
        case 2: model.runtimePaths.singBoxErrorLog
        default: nil
        }
    }
}

private struct LogDetailView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        Form {
            Section("日志文件") {
                RuntimePathRow(title: "更新记录", url: model.runtimePaths.appSupportDirectory.appendingPathComponent("update.log"))
                RuntimePathRow(title: "标准日志", url: model.runtimePaths.singBoxLog)
                RuntimePathRow(title: "错误日志", url: model.runtimePaths.singBoxErrorLog)
            }
            Section("更新记录") {
                Text("更新记录由 RouteBar 写入，包含手动更新、自动更新、订阅解析结果和配置生成结果。sing-box 运行细节仍看标准日志和错误日志。")
                    .foregroundStyle(.secondary)
            }
            Section("排查顺序") {
                Text("1. 先看更新记录确认订阅是否拉取和生成成功。\n2. 再看错误日志是否有配置解析或 Reality 握手错误。\n3. 最后回到节点管理单测节点延迟。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("日志说明")
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("设置").font(.title2.bold())
                Spacer()
                Button("环境设置", systemImage: "wrench.and.screwdriver") { model.showingSetup = true }
            }
            .buttonStyle(.bordered)
            .padding(18)
            Divider()
            Form {
                Section("自动更新") {
                    Toggle("RouteBar 运行时自动更新订阅", isOn: Binding(get: { !model.autoUpdatePaused }, set: { if $0 == model.autoUpdatePaused { model.toggleAutoUpdate() } }))
                    LabeledContent("下次更新", value: model.nextUpdateDate?.formatted(date: .abbreviated, time: .shortened) ?? "已暂停或暂无计划")
                    Text("自动更新只在 RouteBar 进程运行时生效，退出应用后不会后台更新。每个订阅的更新时间在「订阅管理」选择订阅后点「编辑订阅」设置。")
                        .foregroundStyle(.secondary)
                    if !model.subscriptions.isEmpty {
                        ForEach(model.subscriptions) { subscription in
                            LabeledContent(subscription.name, value: "\(subscription.updateIntervalHours) 小时")
                        }
                    }
                }
                Section("托管文件") {
                    RuntimePathRow(title: "sing-box 配置", url: model.runtimePaths.singBoxConfig)
                    RuntimePathRow(title: "Surge 配置", url: model.runtimePaths.surgeProfile)
                    RuntimePathRow(title: "LaunchAgent", url: model.runtimePaths.launchAgent)
                }
            }
            .formStyle(.grouped)
        }
    }
}

private struct SettingsDetailView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        Form {
            Section("数据位置") {
                LabeledContent("订阅地址", value: "Keychain")
                LabeledContent("应用状态", value: "~/Library/Application Support/RouteBar/state.json")
                LabeledContent("生成副本", value: "~/Library/Application Support/RouteBar/")
            }
            Section("托管配置") {
                LabeledContent("sing-box", value: model.runtimePaths.singBoxConfig.path)
                LabeledContent("Surge", value: model.runtimePaths.surgeProfile.path)
            }
            Section("安全边界") {
                Text("当前是个人自用构建，关闭 App Sandbox 以便管理用户目录和 launchctl。后续给别人用时建议改为 helper/权限引导方案。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("设置说明")
    }
}

private struct RuntimeCard: View {
    let title: String; let value: String; let icon: String; let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon).font(.title2).foregroundStyle(tint)
            Text(value).font(.title3.weight(.semibold))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
    }
}

private struct RuntimePathRow: View {
    @EnvironmentObject private var model: AppModel
    let title: String; let url: URL
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.runtimePathExists(url) ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(model.runtimePathExists(url) ? .green : .orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                Text(url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("复制") { model.copyRuntimePath(url) }
            Button("定位") { model.revealRuntimePath(url) }
            Button("打开") { model.openRuntimePath(url) }.disabled(!model.runtimePathExists(url))
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 5)
    }
}

struct EditorContext: Identifiable {
    let id = UUID(); var subscriptionID: UUID?; var name = ""; var url = ""; var note = ""; var interval = 6
    init(subscription: SubscriptionRecord? = nil, url: String = "") { subscriptionID = subscription?.id; name = subscription?.name ?? ""; self.url = url; note = subscription?.note ?? ""; interval = subscription?.updateIntervalHours ?? 6 }
}

private struct SubscriptionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var context: EditorContext
    let save: (UUID?, String, String, String, Int) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(context.subscriptionID == nil ? "添加订阅" : "编辑订阅").font(.title2.bold())
            Form { TextField("名称", text: $context.name); SecureField("订阅 URL", text: $context.url); TextField("备注", text: $context.note); Picker("更新间隔", selection: $context.interval) { Text("1 小时").tag(1); Text("6 小时").tag(6); Text("12 小时").tag(12); Text("24 小时").tag(24) } }.formStyle(.grouped)
            HStack { Spacer(); Button("取消") { dismiss() }; Button("保存") { save(context.subscriptionID, context.name, context.url, context.note, context.interval); dismiss() }.buttonStyle(.borderedProminent).disabled(context.name.isEmpty || URL(string: context.url) == nil) }
        }.padding(24).frame(width: 470)
    }
}
