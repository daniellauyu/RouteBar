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
    @State private var protocolType: ProxyProtocol?
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

                Button {
                    Task { await model.probeGeoForAllNodes() }
                } label: {
                    Label("探测落地", systemImage: "globe")
                }
                .disabled(!model.probingGeoIDs.isEmpty || model.mappedNodes.isEmpty)
                .help("经每个节点的本机端口看流量出公网时落在哪个国家")
            }

            filterBar
            Divider()

            if model.displayedNodes.isEmpty {
                ContentUnavailableView("还没有节点", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text("先在「订阅」页添加并更新一个订阅。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selectedNodeID) {
                    ForEach(filteredNodes) { item in
                        NodeRow(item: item,
                                number: nodeNumbers[item.id],
                                outputName: item.effectiveEnabled ? outputNames[item.id] : nil)
                            .tag(Optional(item.id))
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
                protocolPicker.frame(width: 100)
                regionPicker.frame(width: 110)
                latencyPicker.frame(width: 130)
                sortPicker.frame(width: 110)
            }
            .fixedSize(horizontal: true, vertical: false)

            Grid(horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    sourcePicker.frame(maxWidth: .infinity)
                    protocolPicker.frame(maxWidth: .infinity)
                    regionPicker.frame(maxWidth: .infinity)
                }
                GridRow {
                    latencyPicker.frame(maxWidth: .infinity)
                    sortPicker.frame(maxWidth: .infinity)
                    // 补齐第三格用的占位。必须声明它不参与定尺：`Color` 在两个方向上都是
                    // 无限可拉伸的，不加这一句，它会把所在行撑到 Grid 拿到的任何高度。
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                }
            }
        }
        // 筛选条永远只占它自己的高度。
        //
        // 少了这一句，上面那个 Grid 分支会成为**垂直方向可伸缩**的视图，于是 VStack 把
        // 剩余高度在它和列表之间对半分——两行筛选器被拉开几百点，列表被顶到窗口下半部。
        // 这条路径平时看不见：宽度够时 ViewThatFits 用的是定高的单行 HStack，
        // 只有展开右侧详情把列表栏挤窄之后才会回落到 Grid，症状也就表现为
        // 「一展开详情，整页就乱」。
        .fixedSize(horizontal: false, vertical: true)
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

    private var protocolPicker: some View {
        Picker("协议", selection: $protocolType) {
            Text("全部协议").tag(ProxyProtocol?.none)
            ForEach(ProxyProtocol.allCases) { type in
                Text(type.label).tag(Optional(type))
            }
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
            Text("显示 \(filteredNodes.count) / \(model.displayedNodes.count) 个订阅节点 · \(model.mappedNodes.count) 个启用出口")
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

    /// 节点编号：在完整列表里的位置。
    ///
    /// 不用当前可见的行号，因为这一页可以改排序和筛选——行号会随之变化，说「第 5 个」
    /// 就没有意义了，命令行的 `routebar test 5` 也会指到别的节点上。按完整列表定位，
    /// 筛选和排序都不改变编号，关掉一个节点它也仍占着原来的号。
    ///
    /// 完整列表的顺序（`NodeCatalog.precedes`）和端口分配用的是同一个，所以默认视图下
    /// 这一列是顺的，且第 N 个启用节点就占第 N 个端口。两者曾经各排各的，
    /// 于是 76 号那一行占着 7701 端口、生成名叫 `JSSR-01`。
    private var nodeNumbers: [String: Int] {
        Dictionary(uniqueKeysWithValues: model.displayedNodes.enumerated().map { ($0.element.id, $0.offset + 1) })
    }

    /// 节点 id → 生成的节点名（两种 Surge 接法都用它，机场原名不参与）。
    ///
    /// 整批算一次再按 id 取：名字里的序号取自完整列表的位置，重名补号也只有知道全部名字
    /// 才算得出来，逐行现算既不对也慢。
    private var outputNames: [String: String] {
        model.nodeNaming.namesByEntryID(for: model.mappedNodes)
    }

    // MARK: - 筛选

    private var regions: [String] {
        [Self.allRegions] + Set(model.displayedNodes.map { inferredRegion($0.node.name) }).sorted()
    }

    private var filteredNodes: [DisplayedNode] {
        model.displayedNodes.filter { item in
            let node = item.node
            let search = model.nodeSearchText
            let matchesSearch = search.isEmpty
                || node.name.localizedCaseInsensitiveContains(search)
                || node.server.localizedCaseInsensitiveContains(search)
            let matchesSource = sourceID.map { item.sourceID == $0 } ?? true
            let matchesProtocol = protocolType.map { node.protocolType == $0 } ?? true
            let matchesRegion = region == Self.allRegions || inferredRegion(node.name) == region
            return matchesSearch && matchesSource && matchesProtocol && matchesRegion && matchesLatency(node)
        }
        .sorted { lhs, rhs in
            switch sort {
            case .name:
                lhs.node.name.localizedStandardCompare(rhs.node.name) == .orderedAscending
            case .source:
                lhs.sourceName.localizedStandardCompare(rhs.sourceName) == .orderedAscending
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

}

/// 节点列表行。
private struct NodeRow: View {
    @EnvironmentObject private var model: AppModel
    let item: DisplayedNode
    let number: Int?
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
                set: { model.setNodeEnabled($0, id: item.id) }
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

            // 落地：流量真正出公网时在哪个国家。节点名里写的地区是机场的说法，
            // 两者对不上恰恰是要看见的东西，所以并排放而不是二选一。
            if model.probingGeoIDs.contains(item.id) {
                ProgressView().controlSize(.mini)
            } else if let geo = item.node.geo, geo.outcome == .success, !geo.flag.isEmpty {
                Text(verbatim: geo.flag)
                    .help(geo.label() + (geo.ip.isEmpty ? "" : " · \(geo.ip)"))
            }

            if model.testingNodeIDs.contains(item.id) {
                ProgressView().controlSize(.small)
            } else {
                Text(verbatim: item.node.latencyText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(item.node.latencyTint)
            }
        }
        .padding(.vertical, 5)
        .opacity(item.effectiveEnabled ? 1 : 0.58)
    }

    /// 用 String 拼好再交给 Text。
    ///
    /// `Text("端口 \(int)")` 走的是 SwiftUI 的本地化插值，会给整数加千位分隔符——
    /// 端口 7737 显示成「7,737」，看着像个金额。
    private var subtitle: String {
        let state: String
        if !item.subscriptionEnabled {
            state = "订阅已停用"
        } else if !item.node.isEnabled {
            state = "已关闭"
        } else if let port = item.localPort {
            state = "端口 \(port)"
        } else {
            state = "等待配置"
        }
        return "\(item.node.protocolLabel) · \(item.sourceName) · \(state) · \(item.node.server)"
    }
}
