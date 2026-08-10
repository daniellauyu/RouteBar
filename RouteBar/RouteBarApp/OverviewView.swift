import AppKit
import SwiftUI

/// 概览页：一眼看清「现在能不能用」，以及有没有需要动手的事。
struct OverviewView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                statusHeader
                // 还没配完时，引导排在一切之前——此时那几个指标全是 0，自检也全是红的，
                // 先看到「下一步做什么」比先看到「哪里不对」有用得多。
                if !model.setupChecklist.isComplete {
                    SetupChecklistCard()
                }
                metrics
                healthSection
                pipelineSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 用户可能刚在系统设置里改了登录项，或在别处装好了 sing-box，回到窗口时重新读一次。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshLaunchAtLogin()
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: model.overall.symbol)
                .font(.system(size: 34))
                .foregroundStyle(model.overall.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.overall.label).font(.title2.weight(.semibold))
                Text(model.menuBarSummary).foregroundStyle(.secondary)
            }
            Spacer()
            if model.serviceState.isRunning {
                Button("停止服务", systemImage: "stop.fill") { model.stopService() }
            } else {
                Button("启动服务", systemImage: "play.fill") { model.restartService() }
            }
            Button("更新全部", systemImage: "arrow.clockwise") { Task { await model.updateAll() } }
                .disabled(model.isUpdating)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    private var metrics: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 12)], spacing: 12) {
            MetricTile(title: "订阅",
                       value: "\(model.subscriptions.filter(\.isEnabled).count)/\(model.subscriptions.count)",
                       symbol: "square.3.layers.3d")
            MetricTile(title: "可用节点",
                       value: "\(model.enabledNodeCount)",
                       symbol: "point.3.connected.trianglepath.dotted")
            MetricTile(title: "去重",
                       value: model.deduplicationRate.formatted(.percent.precision(.fractionLength(1))),
                       symbol: "checkmark.shield")
            MetricTile(title: "测速失败",
                       value: "\(model.failedLatencyCount)",
                       symbol: "speedometer",
                       tint: model.failedLatencyCount == 0 ? .secondary : .orange)
        }
    }

    @ViewBuilder
    private var healthSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("自检").font(.headline)
                Spacer()
                Text(model.healthMessages.isEmpty ? "无阻塞问题" : "\(model.healthMessages.count) 项需要处理")
                    .font(.caption)
                    .foregroundStyle(model.healthMessages.isEmpty ? .green : .orange)
            }
            if model.healthMessages.isEmpty {
                Label("订阅、节点、服务与托管配置均正常。", systemImage: "checkmark.circle.fill")
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
    }

    /// 说明 RouteBar 在整条链路里干了什么——用户排查问题时需要知道该去哪一段找。
    private var pipelineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("工作方式").font(.headline)
            InfoCard {
                InfoRow("订阅", "\(model.subscriptions.count) 个源 · 共 \(model.rawNodeCount) 个节点")
                Divider()
                InfoRow("去重", "合并为 \(model.mergedNodes.count) 个 · 启用 \(model.enabledNodeCount) 个")
                Divider()
                InfoRow("sing-box", "每个启用节点一个本机端口，自 7701 起，同端口收 SOCKS5 与 HTTP")
                Divider()
                // 这一行是链路的真正终点：端口摆在那儿，谁来消费都行。
                // 最后一行曾经直接写「Surge」，等于宣布这批端口只有一个去处。
                InfoRow("任何客户端", "填 127.0.0.1 + 端口即可，不需要 Surge")
                Divider()
                InfoRow("Surge（可选）", "按 policy-path 拉走这份现成清单，配置文件原样不动")
            }
            Text("分流规则从来不由 RouteBar 决定，它只负责把可用出口准备好并保持同步。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

}
