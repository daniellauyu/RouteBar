import AppKit
import SwiftUI

/// 通用设置。
///
/// ⌘, 设置窗口与侧栏「通用」页共用这一个视图——两套界面必然发散，而隐藏 Dock 图标后
/// 根本没有 ⌘, 这条路，侧栏那份才是唯一能用的入口。
struct SettingsLandingView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(DockIconVisibility.defaultsKey) private var hidesDockIcon = false
    @AppStorage("appearance") private var appearanceRaw = AppAppearance.system.rawValue
    @AppStorage("defaultWindowSize") private var defaultWindowSizeRaw = DefaultWindowSize.small.rawValue
    @AppStorage("latencyTestURL") private var latencyTestURL = LatencyTestEndpoint.fallback.rawValue
    @AppStorage("latencySamples") private var latencySamples = 3
    @AppStorage("latencyTestUsesCustom") private var usesCustomEndpoint = false
    /// 自定义地址的编辑缓冲。
    ///
    /// 不直接绑到 `latencyTestURL`：那样每敲一个字符都会写进设置，中间态（`htt`、`https:/`）
    /// 会被当成非法值回落到默认端点，选择器随即跳回预设，人还没打完就被打断了。
    @State private var customEndpoint = ""
    /// 节点名模板的编辑缓冲。
    ///
    /// 同样不直接写设置：每敲一个字符都保存的话，会连着触发几十次「保存设置 + 重新生成 +
    /// 重装 Surge 配置」，中间那些半截模板还会被真的写进配置文件。
    @State private var nameTemplate = NodeNaming.defaultTemplate
    @State private var showsNamePreview = false

    /// Picker 用来表示「自定义」的哨兵值。用一个不可能是合法 URL 的字符串，
    /// 免得和用户真填的地址撞上。
    static let customEndpointTag = "routebar.custom-endpoint"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                settingsSection("自动更新") {
                    settingsRow(
                        title: "自动更新订阅",
                        detail: model.autoUpdatePaused
                            ? "已暂停。只有手动点「更新全部」才会拉取。"
                            : "按每条订阅各自的间隔更新。仅在 RouteBar 运行时生效，退出后不会后台更新。",
                        detailColor: model.autoUpdatePaused ? .orange : .secondary
                    ) {
                        Toggle("自动更新订阅", isOn: Binding(
                            get: { !model.autoUpdatePaused },
                            set: { _ in model.toggleAutoUpdate() }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                    Divider()
                    settingsRow(
                        title: "下次更新",
                        detail: "更新间隔在「订阅」页选中订阅后点「编辑」逐条设置。"
                    ) {
                        Text(nextUpdateText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                // 这一节讲的是本地服务，不是「怎么接 Surge」。
                //
                // RouteBar 的产出是节点页上那批本机端口，任何客户端填端口就能用；这里
                // 多给的是一份现成的清单，Surge 可以用 policy-path 直接拉走。曾经这里
                // 还有一个「写入 Surge 配置」的选项——它要改写一份由 Surge 创建、名字
                // 由用户自己起的文件，路径只能靠猜，猜错就报错，已经整个去掉。
                settingsSection("本地服务") {
                    settingsRow(
                        title: "订阅端口",
                        detail: "本地订阅服务监听 127.0.0.1 的这个端口。改动会立即重启服务。"
                    ) {
                        TextField("", value: Binding(
                            get: { model.settings.subscriptionPort },
                            set: { port in
                                guard (1024...65535).contains(port) else { return }
                                var updated = model.settings
                                updated.subscriptionPort = port
                                model.saveSettings(updated)
                            }
                        ), format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                    }
                    Divider()
                    settingsRow(
                        title: "订阅地址",
                        detail: "填进 Surge 策略组的 policy-path=。完整地址与用法见「服务」页。"
                    ) {
                        Button("复制") { model.copyText(model.subscriptionURL) }
                            .controlSize(.small)
                    }
                    Divider()
                    settingsRow(
                        title: "Web 界面",
                        detail: "同端口同令牌的浏览器界面，可在终端里用 open 直接打开，不必切到这个窗口。"
                    ) {
                        HStack(spacing: 6) {
                            Button("复制") { model.copyText(model.webInterfaceURL) }
                            Button("打开") { model.openWebInterface() }
                        }
                        .controlSize(.small)
                    }
                }

                settingsSection("节点命名") {
                    settingsRow(
                        title: "名称模板",
                        detail: templateIsValid
                            ? "决定这些出口在客户端里叫什么。改完按回车生效，会立即重新生成一次配置。"
                            : "模板里一个占位符都没有，所有节点会拼出同一个名字——RouteBar 会自动补序号，免得它们在 Surge 里互相覆盖。",
                        detailColor: templateIsValid ? .secondary : .orange
                    ) {
                        VStack(alignment: .trailing, spacing: 6) {
                            TextField(NodeNaming.defaultTemplate, text: $nameTemplate)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 260)
                                .onSubmit { applyNameTemplate() }
                            HStack(spacing: 6) {
                                // 试跑用的是输入框里的内容，不是已保存的那份——先看结果再决定要不要生效，
                                // 否则「保存了才知道长什么样」，而保存就等于把 Surge 里的名字全改了。
                                Button("测试") { showsNamePreview = true }
                                Button("恢复默认") {
                                    nameTemplate = NodeNaming.defaultTemplate
                                    applyNameTemplate()
                                }
                                .disabled(model.settings.nodeNameTemplate == NodeNaming.defaultTemplate
                                    && nameTemplate == NodeNaming.defaultTemplate)
                            }
                            .controlSize(.small)
                        }
                    }
                    Divider()
                    settingsRow(title: "预览", detail: placeholderHelp) {
                        VStack(alignment: .trailing, spacing: 3) {
                            ForEach(namePreview, id: \.self) { name in
                                Text(name).font(.callout.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Divider()
                    settingsRow(
                        title: "按订阅区分",
                        detail: "在「订阅」页选中订阅点「编辑」，可以给单条订阅单独设一套模板，留空则用上面这一条。"
                    ) {
                        Text(overriddenSubscriptionSummary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                settingsSection("测速") {
                    settingsRow(
                        title: "测试端点",
                        detail: "测速会经本地端口请求这个地址，测的是整条链路（含 TLS 与 Reality 握手），不是 ping。换端点后所有数字会整体平移，不要和换之前的比。"
                    ) {
                        Picker("测试端点", selection: endpointSelection) {
                            ForEach(LatencyTestEndpoint.allCases) { endpoint in
                                Text(endpoint.label).tag(endpoint.rawValue)
                            }
                            Divider()
                            Text("自定义").tag(Self.customEndpointTag)
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }
                    if isCustomEndpoint {
                        settingsRow(
                            title: "自定义地址",
                            detail: "建议用返回 204 空响应的连通性检测地址；返回正文的页面会把下载时间算进延迟。",
                            detailColor: customEndpointIsValid ? .secondary : .orange
                        ) {
                            TextField("https://…", text: $customEndpoint)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 240)
                                .onSubmit { applyCustomEndpoint() }
                                .onChange(of: customEndpoint) { _, _ in applyCustomEndpoint() }
                        }
                    }
                    Divider()
                    settingsRow(
                        title: "每个节点测几次",
                        detail: latencySamples == 1
                            ? "只测一次最快，但单次网络抖动会直接体现为一个离谱的数字。"
                            : "取最好的一次，排除偶发抖动。测试全部节点的耗时大致按次数成倍增加。"
                    ) {
                        Picker("每个节点测几次", selection: $latencySamples) {
                            Text("1 次").tag(1)
                            Text("3 次").tag(3)
                            Text("5 次").tag(5)
                        }
                        .labelsHidden()
                        .frame(width: 100)
                    }
                }

                settingsSection("启动") {
                    settingsRow(
                        title: "登录时自动启动 RouteBar",
                        detail: loginItemDetail,
                        detailColor: loginItemDetailColor
                    ) {
                        VStack(alignment: .trailing, spacing: 8) {
                            // 用真实状态驱动开关，而不是本地布尔：注册成功不等于自启已生效。
                            Toggle("登录时自动启动 RouteBar", isOn: Binding(
                                get: { model.launchesAtLogin },
                                set: { model.setLaunchAtLogin($0) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            if model.loginItemState == .requiresApproval {
                                Button("打开登录项设置") { LoginItem.openSettings() }
                                    .controlSize(.small)
                            }
                        }
                    }
                    Divider()
                    settingsRow(
                        title: "隐藏 Dock 图标",
                        detail: hidesDockIcon
                            ? "已隐藏。点菜单栏图标 →「打开 RouteBar」可唤出主窗口。"
                            : "在 Dock 中显示 RouteBar 图标。隐藏后仍可从菜单栏访问全部功能。"
                    ) {
                        Toggle("隐藏 Dock 图标", isOn: $hidesDockIcon)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .onChange(of: hidesDockIcon) { _, newValue in
                                DockIconVisibility.apply(hidden: newValue)
                            }
                    }
                }

                settingsSection("外观") {
                    settingsRow(title: "主题", detail: "切换浅色 / 深色，或跟随系统设置。") {
                        Picker("主题", selection: $appearanceRaw) {
                            ForEach(AppAppearance.allCases) { option in
                                Label(option.rawValue, systemImage: option.symbol).tag(option.rawValue)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 130)
                    }
                    Divider()
                    settingsRow(title: "默认窗口尺寸", detail: "选择后立即调整当前窗口；也可把手动调好的尺寸设为默认。") {
                        VStack(alignment: .trailing, spacing: 8) {
                            Picker("默认窗口尺寸", selection: $defaultWindowSizeRaw) {
                                ForEach(DefaultWindowSize.allCases) { option in
                                    Text(option.rawValue).tag(option.rawValue)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 110)
                            HStack(spacing: 10) {
                                Text("当前尺寸：\(model.currentWindowDimensions.label)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("设为默认") { model.saveCurrentWindowAsDefault() }
                                    .controlSize(.small)
                            }
                        }
                    }
                }

                settingsSection("数据") {
                    settingsRow(title: "订阅地址", detail: "存放在钥匙串，不写入任何配置文件。") {
                        Label("钥匙串", systemImage: "lock.fill").foregroundStyle(.green)
                    }
                    Divider()
                    settingsRow(title: "应用数据", detail: "订阅元数据、节点与生成副本。") {
                        Button("在访达中显示") { model.reveal(model.runtimePaths.appSupportDirectory) }
                            .controlSize(.small)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 用户可能在系统设置里改了登录项，回到窗口时重读，别让开关停在旧值上。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshLaunchAtLogin()
        }
        .onAppear {
            if usesCustomEndpoint, customEndpoint.isEmpty { customEndpoint = latencyTestURL }
            nameTemplate = model.settings.nodeNameTemplate
        }
        // 命名规则也可能是从网页或命令行改的，回到窗口时对齐，别让输入框停在旧值上。
        .onChange(of: model.settings.nodeNameTemplate) { _, newValue in
            if newValue != NodeNaming.normalized(nameTemplate) { nameTemplate = newValue }
        }
        .sheet(isPresented: $showsNamePreview) {
            NodeNamePreviewView(template: nameTemplate,
                                isApplied: NodeNaming.normalized(nameTemplate) == model.settings.nodeNameTemplate,
                                apply: applyNameTemplate)
        }
    }

    // MARK: - 节点命名

    /// 空模板会被存成默认值，不算错；这里只提醒「一个占位符都没有」的情况——
    /// 那样全部节点会拼出同一个名字，只能靠自动补序号来避免互相覆盖。
    private var templateIsValid: Bool {
        NodeNaming.placeholders.contains { nameTemplate.contains($0.token) }
    }

    private var placeholderHelp: String {
        "可用占位符：" + NodeNaming.placeholders.map { "\($0.token) \($0.summary)" }.joined(separator: "、")
    }

    private var namePreview: [String] {
        NodeNaming.preview(template: nameTemplate,
                           subscriptions: model.subscriptions,
                           mapped: model.mappedNodes)
    }

    private var overriddenSubscriptionSummary: String {
        let count = model.subscriptions.filter { !($0.nodeNameTemplate ?? "").isEmpty }.count
        return count == 0 ? "都跟随全局" : "\(count) 条订阅另有模板"
    }

    private func applyNameTemplate() {
        let normalized = NodeNaming.normalized(nameTemplate)
        nameTemplate = normalized
        guard normalized != model.settings.nodeNameTemplate else { return }
        var updated = model.settings
        updated.nodeNameTemplate = normalized
        model.saveSettings(updated)
    }

    // MARK: - 测速端点

    private var isCustomEndpoint: Bool { usesCustomEndpoint }

    private var customEndpointIsValid: Bool {
        guard let url = URL(string: customEndpoint.trimmingCharacters(in: .whitespaces)) else { return false }
        return url.scheme != nil && url.host != nil
    }

    /// Picker 的选中值：预设时就是那条 URL，自定义时是哨兵值。
    private var endpointSelection: Binding<String> {
        Binding(
            get: { usesCustomEndpoint ? Self.customEndpointTag : latencyTestURL },
            set: { newValue in
                if newValue == Self.customEndpointTag {
                    usesCustomEndpoint = true
                    // 带着当前地址进入编辑，用户通常只想改其中一段。
                    if customEndpoint.isEmpty { customEndpoint = latencyTestURL }
                    applyCustomEndpoint()
                } else {
                    usesCustomEndpoint = false
                    latencyTestURL = newValue
                }
            }
        )
    }

    /// 只有在地址合法时才写进设置，避免半截 URL 让测速悄悄回落到默认端点。
    private func applyCustomEndpoint() {
        guard customEndpointIsValid else { return }
        latencyTestURL = customEndpoint.trimmingCharacters(in: .whitespaces)
    }

    /// 两种方式的代价不一样，得说清楚再让用户选。
    private var nextUpdateText: String {
        guard !model.autoUpdatePaused else { return "已暂停" }
        guard let next = model.nextUpdateDate else { return "暂无计划" }
        return next.formatted(date: .abbreviated, time: .shortened)
    }

    private var loginItemDetail: String {
        switch model.loginItemState {
        case .enabled, .disabled:
            "登录后自动运行，订阅按计划更新。"
        case .requiresApproval:
            "已注册，但需要你在「系统设置 → 通用 → 登录项」中批准后才会真正开机启动。"
        case .failed(let message):
            "无法设置登录项：\(message)（未打包直接运行时注册必然失败，属预期）"
        }
    }

    private var loginItemDetailColor: Color {
        switch model.loginItemState {
        case .enabled, .disabled: .secondary
        case .requiresApproval, .failed: .orange
        }
    }
}
