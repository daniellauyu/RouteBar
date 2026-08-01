import SwiftUI

/// 环境页：RouteBar 依赖的外部路径的检测与配置。
///
/// 原来这是个 900×620 的模态助手，只在首次启动时弹一次；但路径失效（Homebrew 升级、
/// Surge 换配置名）是随时可能发生的事，做成常驻页面，出问题时随时能来改。
struct EnvironmentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft = RouteBarSettings.defaults()
    @State private var hasLoadedDraft = false

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
                    checkCard
                    pathsCard
                }
                .padding(20)
            }
        }
        .task {
            // 只在首次进入时同步草稿，否则用户正在编辑时被后台刷新覆盖掉输入。
            guard !hasLoadedDraft else { return }
            draft = model.settings
            hasLoadedDraft = true
        }
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
                     hint: "必须是已有的 .conf，且含 [Proxy] 与 [Proxy Group] 段")
            Divider()
            checkRow("LaunchAgent", report.launchAgent, RuntimePaths(settings: draft).launchAgent.path,
                     hint: "由你自己安装的 plist，决定 sing-box 如何被 launchd 拉起")
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
