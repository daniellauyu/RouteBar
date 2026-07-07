import SwiftUI

struct SetupAssistantView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: RouteBarSettings

    init() {
        _draft = State(initialValue: RouteBarSettings.defaults())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("RouteBar 环境设置")
                        .font(.title2.bold())
                    Text("新用户需要先确认 sing-box、Surge 配置和 LaunchAgent 的实际位置。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
            }
            .padding(22)

            Divider()

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("检测结果").font(.headline)
                    EnvironmentStatusRow(title: "sing-box 可执行文件", state: report.singBoxBinary, path: RuntimePaths(settings: draft).singBoxBinary.path)
                    EnvironmentStatusRow(title: "Surge Profiles 目录", state: report.surgeProfilesDirectory, path: RuntimePaths(settings: draft).surgeProfilesDirectory.path)
                    EnvironmentStatusRow(title: "Surge 托管配置", state: report.surgeProfile, path: RuntimePaths(settings: draft).surgeProfile.path)
                    EnvironmentStatusRow(title: "sing-box 配置目录", state: report.singBoxConfigDirectory, path: RuntimePaths(settings: draft).singBoxConfigDirectory.path)
                    EnvironmentStatusRow(title: "LaunchAgent", state: report.launchAgent, path: RuntimePaths(settings: draft).launchAgent.path)

                    HStack {
                        Button("创建缺失目录", systemImage: "folder.badge.plus") {
                            model.saveSettings(draft)
                            model.createRequiredDirectories()
                        }
                        Button("使用当前用户默认路径", systemImage: "arrow.counterclockwise") {
                            draft = RouteBarSettings.defaults()
                        }
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
                .frame(width: 320, alignment: .topLeading)

                Form {
                    Section("核心路径") {
                        TextField("sing-box 可执行文件", text: $draft.singBoxBinaryPath)
                        TextField("sing-box 配置", text: $draft.singBoxConfigPath)
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
                .frame(width: 520)
            }
            .padding(22)

            Divider()

            HStack {
                Text(report.needsSetup ? "还有缺失项。可以先保存，之后在设置里继续补齐。" : "环境检测通过。")
                    .font(.caption)
                    .foregroundStyle(report.needsSetup ? .orange : .green)
                Spacer()
                Button("保存设置") {
                    model.saveSettings(draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(22)
        }
        .frame(width: 900, height: 620)
        .onAppear { draft = model.settings }
    }

    private var report: RouteBarEnvironmentReport {
        let paths = RuntimePaths(settings: draft)
        return RouteBarEnvironmentReport(paths: paths) { FileManager.default.fileExists(atPath: $0.path) }
    }
}

private struct EnvironmentStatusRow: View {
    let title: String
    let state: EnvironmentItemState
    let path: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: state == .ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(state == .ready ? .green : .orange)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }
}
