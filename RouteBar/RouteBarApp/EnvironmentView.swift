import SwiftUI

/// 环境页：RouteBar 依赖的外部路径的检测与配置。
///
/// 原来这是个 900×620 的模态助手，只在首次启动时弹一次；但路径失效（Homebrew 升级、
/// Surge 换配置名）是随时可能发生的事，做成常驻页面，出问题时随时能来改。
struct EnvironmentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft = RouteBarSettings.defaults()
    @State private var hasLoadedDraft = false
    @State private var launchAgentState: LaunchAgentState = .missing
    @State private var isInstallingLaunchAgent = false
    @State private var overwritePreview: String?

    var body: some View {
        VStack(spacing: 0) {
            PageBar("RouteBar 需要知道 sing-box、Surge 配置和 LaunchAgent 的实际位置。") {
                Button("恢复默认路径", systemImage: "arrow.counterclockwise") {
                    draft = RouteBarSettings.defaults()
                }
                Button("创建缺失目录", systemImage: "folder.badge.plus") {
                    model.saveSettings(draft)
                    model.createRequiredDirectories()
                }
                Button("保存", systemImage: "checkmark") {
                    model.saveSettings(draft)
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft == model.settings)
            }
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    summaryBanner
                    launchAgentCard
                    checkCard
                    pathsCard
                }
                .padding(20)
            }
        }
        .task {
            // 只在首次进入时同步草稿，否则用户正在编辑时被后台刷新覆盖掉输入。
            if !hasLoadedDraft {
                draft = model.settings
                hasLoadedDraft = true
            }
            launchAgentState = await model.launchAgentState()
        }
        .sheet(isPresented: Binding(
            get: { overwritePreview != nil },
            set: { if !$0 { overwritePreview = nil } }
        )) {
            if let preview = overwritePreview {
                overwriteConfirmation(preview)
            }
        }
    }

    // MARK: - LaunchAgent

    /// LaunchAgent 是唯一一项 RouteBar 能检测出问题、以前却不给任何解法的。
    /// sing-box 由 launchd 拉起，plist 不存在时用户只能自己手写 XML——这一步现在由 RouteBar 负责。
    private var launchAgentCard: some View {
        InfoCard("LaunchAgent") {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: launchAgentSymbol)
                    .foregroundStyle(launchAgentTint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 4) {
                    Text(launchAgentTitle).font(.callout.weight(.medium))
                    Text(launchAgentDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if isInstallingLaunchAgent {
                    ProgressView().controlSize(.small)
                } else if launchAgentState.needsAction {
                    Button(launchAgentActionTitle) { beginLaunchAgentInstall() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var launchAgentSymbol: String {
        switch launchAgentState {
        case .managedUpToDate: "checkmark.circle.fill"
        case .missing, .managedOutdated: "exclamationmark.triangle.fill"
        case .foreign: "hand.raised.fill"
        }
    }

    private var launchAgentTint: Color {
        launchAgentState == .managedUpToDate ? .green : .orange
    }

    private var launchAgentTitle: String {
        switch launchAgentState {
        case .missing: "尚未创建"
        case .managedUpToDate: "由 RouteBar 托管，且与当前设置一致"
        case .managedOutdated: "设置已变更，plist 还是旧的"
        case .foreign: "存在，但不是 RouteBar 创建的"
        }
    }

    private var launchAgentDetail: String {
        switch launchAgentState {
        case .missing:
            "sing-box 由 launchd 拉起并保活。RouteBar 会按上面的路径生成 plist 并立即加载。"
        case .managedUpToDate:
            "plist 内容由「路径设置」派生，改完路径重新生成即可。"
        case .managedOutdated:
            "plist 里的二进制或配置路径与当前设置不符，重新生成后 launchd 才会用新路径。"
        case .foreign:
            "这份 plist 可能含 RouteBar 不知道的字段。覆盖前会先让你过目完整内容，原文件会留一份 .routebar-backup。"
        }
    }

    private var launchAgentActionTitle: String {
        switch launchAgentState {
        case .missing: "创建并加载"
        case .foreign: "查看并覆盖…"
        default: "重新生成"
        }
    }

    private func beginLaunchAgentInstall() {
        Task {
            // 生成 plist 用的是已保存的设置，不是编辑中的草稿——否则写出来的
            // plist 会指向用户还没保存、甚至可能撤销的路径。
            if draft != model.settings { model.saveSettings(draft) }
            if launchAgentState == .foreign {
                overwritePreview = await model.launchAgentPreview()
                return
            }
            await performInstall(allowOverwritingForeignFile: false)
        }
    }

    private func performInstall(allowOverwritingForeignFile: Bool) async {
        isInstallingLaunchAgent = true
        await model.installLaunchAgent(allowOverwritingForeignFile: allowOverwritingForeignFile)
        launchAgentState = await model.launchAgentState()
        isInstallingLaunchAgent = false
    }

    private func overwriteConfirmation(_ preview: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("覆盖已有的 LaunchAgent", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("\(model.runtimePaths.launchAgent.path) 不是 RouteBar 创建的。覆盖后它将变成下面的内容，原文件会保留为 .routebar-backup。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(preview)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(height: 280)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
            HStack {
                Button("在访达中显示原文件") { model.reveal(model.runtimePaths.launchAgent) }
                Spacer()
                Button("取消") { overwritePreview = nil }
                    .keyboardShortcut(.cancelAction)
                Button("覆盖并加载") {
                    overwritePreview = nil
                    Task { await performInstall(allowOverwritingForeignFile: true) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var report: RouteBarEnvironmentReport {
        RouteBarEnvironmentReport(paths: RuntimePaths(settings: draft)) {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    private var summaryBanner: some View {
        Label(
            report.needsSetup
                ? "还有 \(report.missingCount) 项未就位。可以先保存，之后再补齐。"
                : "环境检测通过。",
            systemImage: report.needsSetup ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
        )
        .foregroundStyle(report.needsSetup ? .orange : .green)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((report.needsSetup ? Color.orange : Color.green).opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    private var checkCard: some View {
        InfoCard("检测结果") {
            checkRow("sing-box 可执行文件", report.singBoxBinary, RuntimePaths(settings: draft).singBoxBinary.path,
                     hint: "通常由 Homebrew 安装：brew install sing-box")
            Divider()
            checkRow("sing-box 配置目录", report.singBoxConfigDirectory,
                     RuntimePaths(settings: draft).singBoxConfigDirectory.path,
                     hint: "缺失时点上方「创建缺失目录」即可")
            Divider()
            checkRow("Surge Profiles 目录", report.surgeProfilesDirectory,
                     RuntimePaths(settings: draft).surgeProfilesDirectory.path,
                     hint: "Surge 安装后自动创建")
            Divider()
            checkRow("Surge 托管配置", report.surgeProfile, RuntimePaths(settings: draft).surgeProfile.path,
                     hint: "在 Surge 里新建一份配置即可，只要含 [Proxy] 和 [Proxy Group] 两个段。"
                         + "RouteBar 只改写 [Proxy] 段和「sing-box 节点」策略组，规则和其它策略组原样保留。")
            Divider()
            checkRow("LaunchAgent", report.launchAgent, RuntimePaths(settings: draft).launchAgent.path,
                     hint: "缺失时用上方「LaunchAgent」卡片里的按钮创建")
        }
    }

    private func checkRow(_ title: String, _ state: EnvironmentItemState, _ path: String, hint: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: state == .ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(state == .ready ? .green : .orange)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if state == .missing {
                    Text(hint).font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private var pathsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("路径设置").font(.headline)
            Form {
                Section("sing-box") {
                    TextField("可执行文件", text: $draft.singBoxBinaryPath)
                    TextField("配置文件", text: $draft.singBoxConfigPath)
                    TextField("标准日志", text: $draft.singBoxLogPath)
                    TextField("错误日志", text: $draft.singBoxErrorLogPath)
                }
                Section("Surge 与 LaunchAgent") {
                    TextField("Surge 配置", text: $draft.surgeProfilePath)
                    TextField("LaunchAgent plist", text: $draft.launchAgentPath)
                    TextField("LaunchAgent Label", text: $draft.launchAgentLabel)
                }
            }
            .formStyle(.grouped)
            // 分组表单在很宽的容器里会把标签列推到中间，左边留出一大块空白。
            // 限宽后标签紧跟卡片左缘，和上方检测结果卡片对齐。
            .frame(maxWidth: 720, minHeight: 380, alignment: .leading)

            Text("改动需要点上方「保存」才生效。保存后 RouteBar 会用新路径重新检测服务状态。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
