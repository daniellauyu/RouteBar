import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var section: AppSection?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("仪表盘").font(.title2.bold())
                        Text("RouteBar 统一管理订阅、节点、sing-box 和 Surge 托管配置。")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("更新全部", systemImage: "arrow.clockwise") { Task { await model.updateAll() } }
                        .disabled(model.isUpdating)
                    Button("重启服务", systemImage: "restart") { model.restartService() }
                    Button("刷新自检", systemImage: "checklist") { model.refreshRuntimeArtifacts() }
                }
                .buttonStyle(.bordered).controlSize(.large)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    DashboardMetric(title: "订阅", value: "\(model.summary.enabledSubscriptions)/\(model.summary.totalSubscriptions)", detail: "启用 / 总数", icon: "square.3.layers.3d", tint: .blue)
                    DashboardMetric(title: "节点", value: model.summary.mergedNodes.formatted(), detail: "去重后可用节点", icon: "point.3.connected.trianglepath.dotted", tint: .purple)
                    DashboardMetric(title: "启用节点", value: model.summary.enabledNodes.formatted(), detail: "\(model.summary.disabledNodes) 个已禁用", icon: "checkmark.shield", tint: .green)
                    DashboardMetric(title: "延迟失败", value: model.summary.failedLatencyNodes.formatted(), detail: "\(model.summary.testedNodes) 个已测试", icon: "speedometer", tint: model.summary.failedLatencyNodes == 0 ? .green : .orange)
                    DashboardMetric(title: "服务", value: serviceText, detail: "sing-box LaunchAgent", icon: "bolt.horizontal.circle", tint: serviceTint)
                    DashboardMetric(title: "下次更新", value: nextUpdateText, detail: model.autoUpdatePaused ? "自动更新已暂停" : "运行时自动更新", icon: "clock.arrow.circlepath", tint: model.autoUpdatePaused ? .secondary : .blue)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("自检").font(.headline)
                        Spacer()
                        Text(model.healthMessages.isEmpty ? "无阻塞问题" : "\(model.healthMessages.count) 项需要处理")
                            .font(.caption).foregroundStyle(model.healthMessages.isEmpty ? .green : .orange)
                    }
                    if model.healthMessages.isEmpty {
                        Label("配置入口、订阅状态和服务状态未发现阻塞项。", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    } else {
                        ForEach(model.healthMessages, id: \.self) { message in
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                .padding(14)
                .background(.background, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator))

                HStack(spacing: 12) {
                    QuickActionCard(title: "管理订阅", detail: "添加、编辑、更新订阅", icon: "square.3.layers.3d") { section = .subscriptions }
                    QuickActionCard(title: "管理节点", detail: "筛选、测速、启停节点", icon: "point.3.connected.trianglepath.dotted") { section = .nodes }
                    QuickActionCard(title: "查看日志", detail: "定位 sing-box 输出", icon: "doc.text") { section = .logs }
                }
            }
            .padding(18)
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
    private var nextUpdateText: String {
        guard !model.autoUpdatePaused else { return "已暂停" }
        return model.nextUpdateDate?.formatted(date: .omitted, time: .shortened) ?? "待计算"
    }
}

struct DashboardDetailView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        Form {
            Section("当前方案") {
                LabeledContent("托管 Surge 配置", value: model.runtimePaths.surgeProfile.path)
                LabeledContent("sing-box 配置", value: model.runtimePaths.singBoxConfig.path)
                LabeledContent("LaunchAgent", value: model.runtimePaths.launchctlTarget)
            }
            Section("运行边界") {
                Text("RouteBar 负责订阅解析、节点去重、生成 sing-box 本地 SOCKS 出口，并把这些出口注入 Surge 配置。Surge 后续分流规则直接指向 RouteBar 生成的代理组即可。")
                    .foregroundStyle(.secondary)
            }
            Section("快捷操作") {
                Button("定位 sing-box 配置", systemImage: "folder") { model.revealRuntimePath(model.runtimePaths.singBoxConfig) }
                Button("打开错误日志", systemImage: "doc.text") { model.openRuntimePath(model.runtimePaths.singBoxErrorLog) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("仪表盘说明")
    }
}

private struct DashboardMetric: View {
    let title: String; let value: String; let detail: String; let icon: String; let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon).foregroundStyle(tint)
                Spacer()
            }
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator))
    }
}

private struct QuickActionCard: View {
    let title: String; let detail: String; let icon: String; let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title3).frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator))
    }
}
