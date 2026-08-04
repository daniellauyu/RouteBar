import SwiftUI

/// 首次使用的分步引导，放在概览页顶部，全部必需项做完后自动消失。
///
/// 它和「环境」页不重复：环境页是体检报告加一堆可编辑路径，适合出问题时来排查；
/// 这里只回答第一次打开时唯一的问题——**现在该做什么**，并且每一步都把能代劳的做掉。
struct SetupChecklistCard: View {
    @EnvironmentObject private var model: AppModel

    private static let installCommand = "brew install sing-box"

    var body: some View {
        let checklist = model.setupChecklist
        VStack(alignment: .leading, spacing: 12) {
            header(checklist)
            InfoCard {
                ForEach(Array(checklist.steps.enumerated()), id: \.element.id) { offset, step in
                    if offset > 0 { Divider() }
                    row(step, number: offset + 1)
                }
            }
            Text("这一栏在必需项全部完成后会自动消失。随时可以到「环境」页查看完整的检测结果与路径。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func header(_ checklist: SetupChecklist) -> some View {
        HStack {
            Text("开始使用").font(.headline)
            Spacer()
            Text(checklist.remainingRequiredCount == 0
                 ? "必需项已完成"
                 : "还有 \(checklist.remainingRequiredCount) 步")
                .font(.caption)
                .foregroundStyle(checklist.remainingRequiredCount == 0 ? .green : .orange)
        }
    }

    private func row(_ step: SetupStep, number: Int) -> some View {
        HStack(alignment: .top, spacing: 12) {
            marker(step, number: number)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(step.title).font(.callout.weight(.medium))
                    if step.isOptional {
                        Text("可选").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(step.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !step.isDone, step.kind == .singBox {
                    // 唯一一件 RouteBar 做不了的事，所以把命令原样给出来，可复制可选中。
                    Text(Self.installCommand)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            Spacer(minLength: 12)
            actions(step)
        }
        .padding(.vertical, 9)
    }

    private func marker(_ step: SetupStep, number: Int) -> some View {
        Group {
            if step.isDone {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Text("\(number)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(.quaternary, in: Circle())
            }
        }
        .frame(width: 20, height: 20)
    }

    @ViewBuilder
    private func actions(_ step: SetupStep) -> some View {
        if step.isDone {
            EmptyView()
        } else {
            HStack(spacing: 6) {
                switch step.kind {
                case .singBox:
                    Button("复制命令") { model.copyText(Self.installCommand) }
                    Button("重新检测") { model.redetectSingBox() }
                        .buttonStyle(.borderedProminent)
                case .directories:
                    Button("创建目录") { model.createRequiredDirectories() }
                        .buttonStyle(.borderedProminent)
                case .launchAgent:
                    // 不在这里直接装：plist 可能是用户手写的，覆盖前必须让他过目，
                    // 那套确认流程在「环境」页里，重做一遍只会有两处要维护。
                    Button("去安装") { model.selectedSection = .environment }
                        .buttonStyle(.borderedProminent)
                case .subscription:
                    Button("去添加") { model.selectedSection = .subscriptions }
                        .buttonStyle(.borderedProminent)
                case .surge:
                    if model.settings.surgeOutputMode.servesSubscription {
                        Button("查看服务") { model.selectedSection = .service }
                    } else {
                        Button("去设置路径") { model.selectedSection = .environment }
                            .buttonStyle(.borderedProminent)
                    }
                case .service:
                    Button("启动服务") { model.restartService() }
                        .buttonStyle(.borderedProminent)
                case .autoLaunch:
                    Button("打开") { model.setLaunchAtLogin(true) }
                }
            }
            .controlSize(.small)
        }
    }
}
