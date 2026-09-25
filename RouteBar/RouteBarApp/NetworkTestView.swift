import SwiftUI
import Combine

@MainActor
final class NetworkTestModel: ObservableObject {
    @Published var routeID = "withoutProxy"
    @Published private(set) var isRunning = false
    @Published private(set) var result: NetworkTestResult?
    @Published private(set) var cancelled = false
    private var task: Task<Void, Never>?

    func start(route: NetworkTestRoute, apiKey: String) {
        guard !isRunning else { return }
        result = nil
        cancelled = false
        isRunning = true
        task = Task {
            let report = await NetworkTester().run(route: route, apiKey: apiKey)
            guard !Task.isCancelled else { return }
            result = report
            isRunning = false
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
        cancelled = true
    }
}

struct NetworkTestView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var test: NetworkTestModel
    @State private var apiKey = ""

    private var route: NetworkTestRoute? {
        switch test.routeID {
        case "system": return .system
        case "withoutProxy": return .withoutProxy
        default:
            guard let mapped = model.mappedNodes.first(where: { $0.id == test.routeID }) else { return nil }
            return .node(name: mapped.node.name, port: mapped.localPort)
        }
    }

    private var unavailableNode: Bool {
        if case .node = route { return !model.serviceState.isRunning }
        return route == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            PageBar("检查阿里云连接、IP 访问限制与参考出口。") {
                if test.isRunning {
                    ProgressView().controlSize(.small)
                    Button("取消") { test.cancel() }
                } else {
                    Button("开始测试", systemImage: "network") { start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(unavailableNode || apiKey.contains(where: { $0.isNewline }))
                }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    settings
                    if test.isRunning {
                        Label("正在连接阿里云与两个 IP 检测服务，约需 15 秒…", systemImage: "arrow.triangle.2.circlepath")
                            .font(.callout).foregroundStyle(.secondary)
                    } else if test.cancelled {
                        Text("测试已取消。可以重新选择路径后测试。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let result = test.result { results(result) }
                }
                .padding(20)
            }
        }
        .onDisappear { apiKey = "" }
    }

    private var settings: some View {
        InfoCard("阿里云 DashScope") {
            InfoRow("目标", NetworkTester.target.absoluteString)
            HStack {
                Text("测试路径").font(.callout)
                Spacer()
                Picker("测试路径", selection: $test.routeID) {
                    Text("不使用 HTTP / SOCKS 代理").tag("withoutProxy")
                    Text("系统代理").tag("system")
                    ForEach(model.mappedNodes) { mapped in
                        Text("\(mapped.node.name) · :\(mapped.localPort)").tag(mapped.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 360)
                .disabled(test.isRunning)
            }
            .padding(.vertical, 8)
            Text(route?.explanation ?? "所选节点已不可用，请重新选择路径。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)
            if unavailableNode {
                Text("使用节点测试前，请启动 sing-box 并选择可用节点。")
                    .font(.caption).foregroundStyle(.orange).padding(.bottom, 12)
            }
            Divider()
            SecureField("API Key（可选，用于检查访问限制）", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .disabled(test.isRunning)
                .padding(.vertical, 12)
            Text("仅请求模型列表，不发送对话。密钥仅用于本次阿里云请求，不保存；留空时只检查连接，不能验证白名单。参考 IP 由 myip.ipip.net 和 Cloudflare 提供。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func results(_ result: NetworkTestResult) -> some View {
        InfoCard("测试结果") {
            Label(result.summary, systemImage: result.ipRestricted || result.response.failure != nil
                  ? "exclamationmark.triangle" : "network")
                .font(.headline)
                .foregroundStyle(result.ipRestricted || result.response.failure != nil ? Color.orange : Color.primary)
                .padding(.bottom, 8)
            InfoRow("测试时间", result.testedAt.formatted(date: .abbreviated, time: .standard))
            InfoRow("本次路径", result.route.title)
            InfoRow("阿里云看到的公网 IP", "未确认")
            Text(result.sourceIPExplanation)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 8)
        }

        InfoCard("参考出口 IP") {
            ForEach(result.references, id: \.service) { reference in
                InfoRow(reference.service, reference.address ?? reference.failure ?? "未获取")
            }
            if result.referenceIPsDiffer {
                Label("两个网站返回不同 IP，存在分流或多出口。", systemImage: "arrow.triangle.branch")
                    .font(.callout).foregroundStyle(.orange).padding(.top, 8)
            }
            Text("即使两处 IP 相同，也不能证明阿里云使用相同出口。此测试不自动复用 OpenCode 的环境变量。")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
        }

        InfoCard("阿里云响应") {
            InfoRow("HTTP 状态", result.response.statusCode.map(String.init) ?? "未收到响应")
            InfoRow("请求耗时", "\(Int(result.response.elapsed * 1000)) ms")
            if let code = result.errorCode { InfoRow("错误码", code) }
            if let message = result.message {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled).padding(.vertical, 8)
            }
            if let requestID = result.response.requestID { InfoRow("Request ID", requestID) }
            if let local = result.response.localAddress { InfoRow("本机连接地址（非公网出口）", local) }
            if let remote = result.response.remoteAddress { InfoRow("连接对端（非出口 IP）", remote) }
            if let usedProxy = result.response.usedProxy {
                InfoRow("HTTP / SOCKS 代理", usedProxy ? "连接使用了代理" : "连接未使用显式代理（可能经 TUN）")
            }
            Text("需要精确来源 IP 时，可提供 Request ID 和测试时间，请阿里云侧核对请求。")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
        }
        HStack {
            Spacer()
            Button("复制诊断报告", systemImage: "doc.on.doc") { model.copyText(result.report) }
        }
    }

    private func start() {
        guard let route else { return }
        let key = apiKey
        apiKey = ""
        test.start(route: route, apiKey: key)
    }
}
