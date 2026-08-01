import SwiftUI

/// 服务页：sing-box 的运行状态、托管文件与它自己的日志。
///
/// 原来这些内容分散在「服务管理」「日志」「设置」三页，排查一次问题要来回跳；
/// 现在与 sing-box 进程有关的一切都在这一页，「运行日志」页只留 RouteBar 自身的记录。
struct ServiceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedLog = LogFile.error

    private enum LogFile: String, CaseIterable, Identifiable {
        case error = "错误日志"
        case standard = "标准日志"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageBar("RouteBar 通过 launchctl 管理 sing-box 的 LaunchAgent。") {
                Button("刷新", systemImage: "arrow.clockwise") { model.refreshService() }
                if model.serviceState.isRunning {
                    Button("停止", systemImage: "stop.fill") { model.stopService() }
                } else {
                    Button("启动", systemImage: "play.fill") { model.restartService() }
                }
                Button("重新生成并重启", systemImage: "arrow.triangle.2.circlepath") { model.regenerate() }
            }
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    statusCard
                    subscriptionCard
                    filesCard
                    logCard
                }
                .padding(20)
            }
        }
        .task {
            await model.refreshLogs()
            await model.refreshSubscriptionStatus()
        }
    }

    private var statusCard: some View {
        InfoCard {
            HStack(spacing: 14) {
                Image(systemName: model.serviceState.symbol)
                    .font(.system(size: 30))
                    .foregroundStyle(model.serviceState.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("sing-box \(model.serviceState.label)").font(.title3.weight(.semibold))
                    Text(model.runtimePaths.launchctlTarget)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let reason = model.serviceState.failureReason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(model.enabledNodeCount)").font(.title.weight(.semibold)).monospacedDigit()
                    Text("个本地出口").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 本地订阅地址。只在启用了该输出方式时出现。
    @ViewBuilder
    private var subscriptionCard: some View {
        if model.settings.surgeOutputMode.servesSubscription {
            InfoCard("本地订阅地址") {
                HStack(spacing: 10) {
                    Circle()
                        .fill(model.subscriptionServing ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(model.subscriptionServing ? "服务中" : (model.subscriptionError ?? "未启动"))
                        .font(.callout)
                        .foregroundStyle(model.subscriptionServing ? Color.primary : Color.orange)
                    Spacer()
                    Button("复制地址", systemImage: "doc.on.doc") {
                        model.copyText(model.subscriptionURL)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Divider()
                Text(model.subscriptionURL)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("在 Surge 策略组里这样用（和你接 sub.store 是同一个机制）：")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("🔰 RouteBar = select, policy-path=\(model.subscriptionURL), update-interval=0")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("只在 RouteBar 运行时可访问。Surge 会缓存上一次拉到的列表，所以 RouteBar 没开时不会立刻断，但也拿不到新节点。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
            }
        }
    }

    private var filesCard: some View {
        InfoCard("托管文件") {
            PathRow(title: "sing-box 配置", url: model.runtimePaths.singBoxConfig)
            Divider()
            PathRow(title: "Surge 配置", url: model.runtimePaths.surgeProfile)
            Divider()
            PathRow(title: "LaunchAgent", url: model.runtimePaths.launchAgent)
            Divider()
            PathRow(title: "sing-box 可执行文件", url: model.runtimePaths.singBoxBinary)
        }
    }

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("sing-box 日志").font(.headline)
                Spacer()
                Picker("", selection: $selectedLog) {
                    ForEach(LogFile.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                Button("复制", systemImage: "doc.on.doc") { model.copyText(logText) }
                Button("打开文件", systemImage: "doc.text") { model.open(logURL) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            ScrollView {
                Text(logText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(height: 240)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))

            Text("排查顺序：先看错误日志有没有配置解析或 Reality 握手报错，再回到「运行日志」看 RouteBar 这边做了什么。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var logText: String {
        switch selectedLog {
        case .error: model.singBoxErrorLogText
        case .standard: model.singBoxLogText
        }
    }

    private var logURL: URL {
        switch selectedLog {
        case .error: model.runtimePaths.singBoxErrorLog
        case .standard: model.runtimePaths.singBoxLog
        }
    }
}
