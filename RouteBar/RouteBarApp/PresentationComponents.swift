import SwiftUI

// MARK: - 基础组件

/// 状态胶囊。
struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }
}

/// 指标块。概览页与各页头部共用一种，避免每页各画一套卡片后风格发散。
struct MetricTile: View {
    let title: String
    let value: String
    let symbol: String
    var tint: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(tint)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// 页面顶部条：一句说明 + 右侧操作。
///
/// 这里**不再重复页面标题**——窗口标题栏已经由 `navigationTitle` 显示当前分区名，
/// 页内再写一遍大标题，同一个词会在上下相邻两行各出现一次。
struct PageBar<Actions: View>: View {
    let subtitle: String
    @ViewBuilder var actions: Actions

    init(_ subtitle: String, @ViewBuilder actions: () -> Actions) {
        self.subtitle = subtitle
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 16)
            HStack(spacing: 8) { actions }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

// MARK: - 卡片与信息行

/// 详情卡片容器。
struct InfoCard<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title).font(.headline)
            }
            VStack(alignment: .leading, spacing: 0) { content }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}

/// 卡片里的一行「名称 — 值」。
struct InfoRow<Value: View>: View {
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
            Text(title).font(.callout)
            Spacer(minLength: 16)
            value
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .lineLimit(3)
        }
        .padding(.vertical, 7)
    }
}

// MARK: - 设置分组

/// 设置分组卡片。「通用」「环境」两页共用，避免各写一套样式后发散。
func settingsSection<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 12) {
        Text(title).font(.headline)
        VStack(spacing: 0) { content() }
            .padding(.horizontal, 16)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// 设置分组内的单行：左侧标题 + 说明，右侧控件。
func settingsRow<Control: View>(
    title: String,
    detail: String,
    detailColor: Color = .secondary,
    @ViewBuilder control: () -> Control
) -> some View {
    HStack(alignment: .center, spacing: 20) {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.body.weight(.medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(detailColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 24)
        control()
    }
    .padding(.vertical, 15)
}

// MARK: - 托管文件行

/// 一个 RouteBar 读写的外部文件：存在与否 + 复制 / 定位 / 打开。
///
/// 服务页、环境页都要展示同一批路径，做成一个组件，三处按钮的行为才必然一致。
struct PathRow: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    let url: URL

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: exists ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(exists ? .green : .orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                Text(url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            Button("复制") { model.copyText(url.path) }
            Button("定位") { model.reveal(url) }
            Button("打开") { model.open(url) }.disabled(!exists)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.vertical, 7)
    }

    private var exists: Bool { model.pathExists(url) }
}

// MARK: - 共享展示辅助

extension OverallStatus {
    var symbol: String {
        switch self {
        case .running: "checkmark.circle.fill"
        case .stopped: "pause.circle.fill"
        case .needsAttention: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .running: .green
        case .stopped: .secondary
        case .needsAttention: .orange
        case .failed: .red
        }
    }
}

extension ServiceState {
    var tint: Color {
        switch self {
        case .running: .green
        case .stopped: .secondary
        case .failed: .red
        }
    }
}

extension SubscriptionStatus {
    var tint: Color {
        switch self {
        case .success: .green
        case .failed: .red
        case .updating: .blue
        case .idle, .disabled: .secondary
        }
    }
}

extension ProxyNode {
    /// 延迟展示文本：未测过、失败和具体毫秒数是三种不同的信息，不能都显示成「—」。
    var latencyText: String {
        guard let latency else { return "未测试" }
        if let milliseconds = latency.milliseconds { return "\(milliseconds) ms" }
        return latency.outcome.label
    }

    var latencyTint: Color {
        guard let latency else { return .secondary }
        guard let milliseconds = latency.milliseconds else { return .red }
        return milliseconds < 100 ? .green : milliseconds <= 200 ? .orange : .red
    }
}

/// 相对时间，用于「上次更新」这类不需要精确到秒的场合。
func relativeTime(_ date: Date?) -> String {
    guard let date else { return "尚未更新" }
    let seconds = max(0, Int(-date.timeIntervalSinceNow))
    if seconds < 60 { return "刚刚" }
    if seconds < 3600 { return "\(seconds / 60) 分钟前" }
    if seconds < 86400 { return "\(seconds / 3600) 小时前" }
    return "\(seconds / 86400) 天前"
}

/// 从节点名推断地区，用于节点页筛选。机场命名没有标准，只能按常见关键词猜。
func inferredRegion(_ name: String) -> String {
    let pairs = [
        ("香港", ["香港", "HK", "Hong Kong"]),
        ("日本", ["日本", "东京", "大阪", "JP", "Japan"]),
        ("美国", ["美国", "洛杉矶", "US", "United States"]),
        ("新加坡", ["新加坡", "狮城", "SG", "Singapore"]),
        ("台湾", ["台湾", "台北", "TW", "Taiwan"]),
        ("韩国", ["韩国", "首尔", "KR", "Korea"]),
    ]
    return pairs.first { pair in pair.1.contains { name.localizedCaseInsensitiveContains($0) } }?.0 ?? "其他"
}
