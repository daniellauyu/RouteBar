import SwiftUI

/// 服务页：sing-box 的运行状态、托管文件与它自己的日志。
///
/// 原来这些内容分散在「服务管理」「日志」「设置」三页，排查一次问题要来回跳；
/// 现在与 sing-box 进程有关的一切都在这一页，「日志」页只留 RouteBar 自身的记录。
struct ServiceView: View {
    @EnvironmentObject private var model: AppModel

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

    /// 本地订阅地址与 Web 界面。现在是唯一的输出方式，所以无条件出现。
    private var subscriptionCard: some View {
        Group {
            InfoCard("本地服务") {
                HStack(spacing: 10) {
                    Circle()
                        .fill(model.subscriptionServing ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(model.subscriptionServing ? "服务中" : (model.subscriptionError ?? "未启动"))
                        .font(.callout)
                        .foregroundStyle(model.subscriptionServing ? Color.primary : Color.orange)
                    Spacer()
                    Button("打开 Web 界面", systemImage: "safari") { model.openWebInterface() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("复制地址", systemImage: "doc.on.doc") {
                        model.copyText(model.subscriptionURL)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    // 「Surge 格式」而不是「给 Surge」：这地址吐的是 policy 行，
                    // 别的客户端拿去用不了，它们要的是节点页上那批端口。
                    Text("订阅地址（Surge 格式）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(model.subscriptionURL)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Web 界面（给浏览器）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    Text(model.webInterfaceURL)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
                    Text("两个地址都只在 RouteBar 运行时可访问，且只绑定 127.0.0.1。Surge 会缓存上一次拉到的列表，所以 RouteBar 没开时不会立刻断，但也拿不到新节点。")
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
            PathRow(title: "LaunchAgent", url: model.runtimePaths.launchAgent)
            Divider()
            PathRow(title: "sing-box 可执行文件", url: model.runtimePaths.singBoxBinary)
        }
    }

    /// sing-box 日志。
    ///
    /// 这里不再原样贴一大块文本：那份文件里 95% 是每条连接一行的 INFO，滚动着看
    /// 根本挑不出问题。真正要紧的（握手失败、端口占用、配置错误）已经按时间并进
    /// 「日志」页，和 RouteBar 自己的记录排在一起。这张卡片只负责两件事：
    /// 让你能打开原始文件，以及把它清掉。
    private var logCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("sing-box 日志").font(.headline)
            InfoCard {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "text.book.closed")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("这份文件的内容已并入「日志」页").font(.callout.weight(.medium))
                        Text("和 RouteBar 自己的记录按日期归档在一起，可按时段、级别、来源筛选，"
                             + "保留 \(LogArchiveStore.retentionDays) 天。"
                             + "sing-box 的日志级别是 warn，所以下面这份原始文件不会再因为逐条连接而疯长；"
                             + "清空它不会动已经归档的历史。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Button("去看") { model.selectedSection = .logs }
                        .controlSize(.small)
                }
                .padding(.vertical, 6)
                Divider()
                PathRow(title: "sing-box 日志文件", url: model.runtimePaths.singBoxErrorLog)
                Divider()
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("清空日志文件").font(.callout.weight(.medium))
                        Text(logSizeDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Button("清空", role: .destructive) { model.clearSingBoxLogs() }
                        .controlSize(.small)
                }
                .padding(.vertical, 6)
            }
        }
    }

    /// 直接把体积摆出来。旧版本用 info 级别跑了多久，这个数字就有多难看，
    /// 而不给出来的话没人会想到去清。
    private var logSizeDescription: String {
        let url = model.runtimePaths.singBoxErrorLog
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
            return "当前没有日志文件。"
        }
        let text = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        return "当前 \(text)。截断文件本身，sing-box 会继续往里写新的。"
    }
}
