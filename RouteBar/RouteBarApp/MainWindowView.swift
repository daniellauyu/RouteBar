import SwiftUI

/// 主窗口：侧栏 + 单一详情区。
///
/// 原来是三栏（自绘侧栏 / 内容 / 详情），第三栏在多数页面里塞的是「XX 说明」这类静态文字，
/// 既占掉三分之一宽度又不承载操作。现在改成系统标准的两栏：真正需要「列表 + 详情」的
/// 订阅页和节点页在自己的页面内部分栏（见 `SubscriptionsView` / `NodesView`），
/// 其余页面独占整个详情区。
struct MainWindowView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            page
                .frame(minWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(model.selectedSection.rawValue)
        .onChange(of: model.selectedSection) { _, section in
            guard !section.hasSelection else { return }
            model.selectedSubscriptionID = nil
            model.selectedNodeID = nil
        }
    }

    // MARK: - 侧栏

    private var sidebar: some View {
        List(selection: $model.selectedSection) {
            ForEach(SidebarGroup.allCases) { group in
                Section(group.rawValue) {
                    ForEach(group.sections) { section in
                        Label(section.rawValue, systemImage: section.symbol)
                            .badge(model.badge(for: section).map { Text("\($0)") })
                            .tag(section)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 216, max: 260)
        .safeAreaInset(edge: .bottom) { sidebarFooter }
    }

    /// 侧栏底部：服务状态 + 更新入口。
    ///
    /// 这两件事在任何页面下都可能想立刻做一下，固定在侧栏底部就不必先切页面。
    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            Button {
                model.selectedSection = .service
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(model.serviceState.tint)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("sing-box \(model.serviceState.label)")
                            .font(.callout.weight(.medium))
                        Text(model.overall == .needsAttention
                             ? "\(model.healthMessages.count) 项待处理"
                             : "\(model.enabledNodeCount) 个节点在用")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.top, 10)

            Button {
                Task { await model.updateAll() }
            } label: {
                HStack(spacing: 8) {
                    if model.isUpdating {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.isUpdating ? "正在更新…" : "更新全部订阅")
                            .font(.callout.weight(.medium))
                        Text(nextUpdateText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.isUpdating)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
    }

    private var nextUpdateText: String {
        if model.autoUpdatePaused { return "自动更新已暂停" }
        guard let next = model.nextUpdateDate else { return "暂无更新计划" }
        return next <= .now
            ? "有订阅已到期"
            : "下次 \(next.formatted(date: .omitted, time: .shortened))"
    }

    // MARK: - 详情区

    @ViewBuilder
    private var page: some View {
        switch model.selectedSection {
        case .overview: OverviewView()
        case .setup: SetupView()
        case .subscriptions: SubscriptionsView()
        case .nodes: NodesView()
        case .service: ServiceView()
        case .logs: LogView()
        case .settings: SettingsLandingView()
        case .environment: EnvironmentView()
        case .about: AboutView()
        }
    }
}
