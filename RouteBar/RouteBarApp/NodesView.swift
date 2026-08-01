import SwiftUI

private enum NodeLatencyFilter: String, CaseIterable, Identifiable {
    case all = "全部延迟"
    case fast = "低于 100 ms"
    case medium = "100–200 ms"
    case slow = "高于 200 ms"
    case failed = "不可用"
    case untested = "未测试"

    var id: String { rawValue }
}

private enum NodeSort: String, CaseIterable, Identifiable {
    case name = "按名称"
    case latency = "按延迟"
    case source = "按来源"

    var id: String { rawValue }
}

/// 节点页：左列表 + 右详情，筛选条收进工具栏区域。
struct NodesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var sourceID: UUID?
    @State private var region = allRegions
    @State private var latencyFilter: NodeLatencyFilter = .all
    @State private var sort: NodeSort = .name

    private static let allRegions = "全部地区"

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                listPane
                    .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                if model.selectedNode != nil {
                    Divider()
                    NodeInspectorView()
                        .frame(width: min(420, max(300, proxy.size.width * 0.34)))
                        .frame(maxHeight: .infinity)
                }
            }
        }
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            PageBar("启用的节点会各自占用一个本地端口，并出现在 Surge 的代理列表里。") {
                Button {
                    Task { await model.testAllNodes() }
                } label: {
                    Label("测试全部", systemImage: "speedometer")
                }
                .disabled(!model.testingNodeIDs.isEmpty || model.mappedNodes.isEmpty)
            }

            filterBar
            Divider()

            if model.mergedNodes.isEmpty {
                ContentUnavailableView("还没有节点", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text("先在「订阅」页添加并更新一个订阅。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selectedNodeID) {
                    ForEach(filteredNodes) { item in
                        NodeRow(item: item, source: sourceName(for: item.node))
                            .tag(Optional(item.node.id))
                    }
                }
                .overlay {
                    if filteredNodes.isEmpty {
                        ContentUnavailableView("没有匹配的节点", systemImage: "line.3.horizontal.decrease.circle",
                                               description: Text("放宽筛选条件试试。"))
                    }
                }
                statusBar
            }
        }
        .searchable(text: $model.nodeSearchText, placement: .toolbar, prompt: "搜索节点名称或服务器")
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            Picker("订阅", selection: $sourceID) {
                Text("全部订阅").tag(UUID?.none)
                ForEach(model.subscriptions) { Text($0.name).tag(Optional($0.id)) }
            }
            .labelsHidden()
            .frame(width: 140)

            Picker("地区", selection: $region) {
                ForEach(regions, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 110)

            Picker("延迟", selection: $latencyFilter) {
                ForEach(NodeLatencyFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 130)

            Picker("排序", selection: $sort) {
                ForEach(NodeSort.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 110)

            Spacer()
        }
        .controlSize(.small)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var statusBar: some View {
        HStack {
            Text("显示 \(filteredNodes.count) / \(model.mappedNodes.count) 个启用节点")
            Spacer()
            if !model.testingNodeIDs.isEmpty {
                ProgressView().controlSize(.small)
                Text("正在测速 \(model.testingNodeIDs.count) 个")
            } else if model.testedNodeCount > 0 {
                Text("已测速 \(model.testedNodeCount) · 失败 \(model.failedLatencyCount)")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .frame(height: 34)
        .background(.bar)
    }

    // MARK: - 筛选

    private var regions: [String] {
        [Self.allRegions] + Set(model.mappedNodes.map { inferredRegion($0.node.name) }).sorted()
    }

    private var filteredNodes: [PortMappedNode] {
        model.mappedNodes.filter { item in
            let node = item.node
            let search = model.nodeSearchText
            let matchesSearch = search.isEmpty
                || node.name.localizedCaseInsensitiveContains(search)
                || node.server.localizedCaseInsensitiveContains(search)
            let matchesSource = sourceID.map { node.sourceIDs.contains($0) } ?? true
            let matchesRegion = region == Self.allRegions || inferredRegion(node.name) == region
            return matchesSearch && matchesSource && matchesRegion && matchesLatency(node)
        }
        .sorted { lhs, rhs in
            switch sort {
            case .name:
                lhs.node.name.localizedStandardCompare(rhs.node.name) == .orderedAscending
            case .source:
                sourceName(for: lhs.node).localizedStandardCompare(sourceName(for: rhs.node)) == .orderedAscending
            case .latency:
                // 未测速的排最后，否则它们会以 0 ms 霸占榜首。
                (lhs.node.latency?.milliseconds ?? Int.max) < (rhs.node.latency?.milliseconds ?? Int.max)
            }
        }
    }

    private func matchesLatency(_ node: ProxyNode) -> Bool {
        switch latencyFilter {
        case .all: true
        case .untested: node.latency == nil
        case .failed: node.latency != nil && node.latency?.outcome != .success
        case .fast: (node.latency?.milliseconds).map { $0 < 100 } ?? false
        case .medium: (node.latency?.milliseconds).map { (100...200).contains($0) } ?? false
        case .slow: (node.latency?.milliseconds).map { $0 > 200 } ?? false
        }
    }

    private func sourceName(for node: ProxyNode) -> String {
        model.sourceNames(for: node).first ?? "未知"
    }
}

/// 节点列表行。
private struct NodeRow: View {
    @EnvironmentObject private var model: AppModel
    let item: PortMappedNode
    let source: String

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { item.node.isEnabled },
                set: { model.setNodeEnabled($0, id: item.node.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.node.name).font(.body.weight(.medium)).lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if model.testingNodeIDs.contains(item.node.id) {
                ProgressView().controlSize(.small)
            } else {
                Text(verbatim: item.node.latencyText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(item.node.latencyTint)
            }
        }
        .padding(.vertical, 5)
    }

    /// 用 String 拼好再交给 Text。
    ///
    /// `Text("端口 \(int)")` 走的是 SwiftUI 的本地化插值，会给整数加千位分隔符——
    /// 端口 7737 显示成「7,737」，看着像个金额。
    private var subtitle: String {
        "\(source) · 端口 \(item.localPort) · \(item.node.server)"
    }
}
