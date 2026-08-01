import SwiftUI

/// 概览页：一眼看清「现在能不能用」，以及有没有需要动手的事。
struct OverviewView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                statusHeader
                metrics
                healthSection
                pipelineSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                InfoRow("sing-box", "每个启用节点一个本地 SOCKS 端口，自 7701 起")
                Divider()
                InfoRow("Surge", "这些端口写入 [Proxy] 与「sing-box 节点」策略组")
            }
            Text("分流规则仍由 Surge 决定；RouteBar 只负责把可用出口准备好并保持同步。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
