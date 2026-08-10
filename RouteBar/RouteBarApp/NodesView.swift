import SwiftUI

private enum NodeLatencyFilter: String, CaseIterable, Identifiable {
    case all, fast, medium, slow, failed, untested

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "全部延迟"
        case .fast: "低于 \(LatencyClassification.fastUpperBound) ms"
        case .medium: "\(LatencyClassification.fastUpperBound)–\(LatencyClassification.mediumUpperBound) ms"
        case .slow: "高于 \(LatencyClassification.mediumUpperBound) ms"
        case .failed: "不可用"
        case .untested: "未测试"
        }
    }
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
            // 只说端口，不说 Surge：端口是无条件成立的事实，Surge 只在写配置那种模式下
            // 才成立。原来那句「并出现在 Surge 的代理列表里」在订阅模式和不用 Surge 的人
            // 那里都是错的，还顺手把这批端口说成了 Surge 的附属品。
            PageBar("每个启用的节点占一个本机端口，同端口同时收 SOCKS5 和 HTTP，只监听 127.0.0.1。") {
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
                        NodeRow(item: item,
                                number: nodeNumbers[item.node.id],
                                source: sourceName(for: item.node),
                                outputName: outputNames[item.node.id])
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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                sourcePicker.frame(width: 140)
                regionPicker.frame(width: 110)
                latencyPicker.frame(width: 130)
                sortPicker.frame(width: 110)
            }
            .fixedSize(horizontal: true, vertical: false)

            Grid(horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    sourcePicker.frame(maxWidth: .infinity)
                    regionPicker.frame(maxWidth: .infinity)
                }
                GridRow {
                    latencyPicker.frame(maxWidth: .infinity)
                    sortPicker.frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .controlSize(.small)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var sourcePicker: some View {
        Picker("订阅", selection: $sourceID) {
            Text("全部订阅").tag(UUID?.none)
            ForEach(model.subscriptions) { Text($0.name).tag(Optional($0.id)) }
        }
        .labelsHidden()
    }

    private var regionPicker: some View {
        Picker("地区", selection: $region) {
            ForEach(regions, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
    }

    private var latencyPicker: some View {
        Picker("延迟", selection: $latencyFilter) {
            ForEach(NodeLatencyFilter.allCases) { Text($0.label).tag($0) }
        }
        .labelsHidden()
    }

    private var sortPicker: some View {
        Picker("排序", selection: $sort) {
            ForEach(NodeSort.allCases) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden()
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

    // MARK: - 序号

    /// 节点编号：在**完整节点列表**（去重后按名称排序）里的位置。
    ///
    /// 不用列表行号，因为这一页可以改排序和筛选——行号会随之变化，说「第 5 个」就没有意义了。
    /// 按完整列表定位则三处一致：窗口、网页、`routebar test 5` 指的是同一个节点。
    ///
    /// 这一页只列启用节点（`mappedNodes` 已过滤），所以有节点被停用时编号会跳号——
    /// 那是对的，编号属于节点，不属于它此刻排第几行。
    private var nodeNumbers: [String: Int] {
        Dictionary(uniqueKeysWithValues: model.mergedNodes.enumerated().map { ($0.element.id, $0.offset + 1) })
    }

    /// 节点 id → 生成的节点名（两种 Surge 接法都用它，机场原名不参与）。
    ///
    /// 整批算一次再按 id 取：名字里的序号取自完整列表的位置，重名补号也只有知道全部名字
    /// 才算得出来，逐行现算既不对也慢。
    private var outputNames: [String: String] {
        model.nodeNaming.namesByNodeID(for: model.mappedNodes)
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
        case .untested: LatencyClassification.band(for: node.latency) == .untested
        case .failed: LatencyClassification.band(for: node.latency) == .failed
        case .fast: LatencyClassification.band(for: node.latency) == .fast
        case .medium: LatencyClassification.band(for: node.latency) == .medium
        case .slow: LatencyClassification.band(for: node.latency) == .slow
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
    let number: Int?
    let source: String
    /// 由命名模板拼出来的节点名。与上面那行机场给的原名并列显示——
    /// 命名模板可配置之后，两者可以完全不一样，在策略组里找不到某个节点时要对的是这个。
    let outputName: String?

    var body: some View {
        HStack(spacing: 12) {
            Text(number.map(String.init) ?? "–")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 26, alignment: .trailing)

            Toggle("", isOn: Binding(
                get: { item.node.isEnabled },
                set: { model.setNodeEnabled($0, id: item.node.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.node.name).font(.body.weight(.medium)).lineLimit(1)
                    if let outputName {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Text(outputName)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help("生成的节点名。写入 Surge 配置与订阅地址两种方式用的都是它")
                    }
                }
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
        "\(item.node.protocolLabel) · \(source) · 端口 \(item.localPort) · \(item.node.server)"
    }
}
