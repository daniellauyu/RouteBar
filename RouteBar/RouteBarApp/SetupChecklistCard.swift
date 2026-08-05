import SwiftUI

/// 首次使用的分步引导。
///
/// 它和「环境」页不重复：环境页是体检报告加一堆可编辑路径，适合出问题时来排查；
/// 这里只回答第一次打开时唯一的问题——**现在该做什么**，并且每一步都把能代劳的做掉。
///
/// 两个地方用同一份视图：概览页顶部（未配完时才出现，保证首次启动第一眼就看得到）
/// 和常驻的「开始使用」页。差别只在标题与页脚——步骤列表本身必须是同一段代码，
/// 各写一遍必然会在改了一处后漂移。
struct SetupChecklistCard: View {
    /// 摆在哪儿。页面版的标题由 `navigationTitle` 与 `PageBar` 承担，不必自带。
    enum Context {
        case overview
        case page
    }

    @EnvironmentObject private var model: AppModel

    var context: Context = .overview

    var body: some View {
        let checklist = model.setupChecklist
        VStack(alignment: .leading, spacing: 12) {
            if context == .overview {
                header(checklist)
            }
            InfoCard {
                ForEach(Array(checklist.steps.enumerated()), id: \.element.id) { offset, step in
                    if offset > 0 { Divider() }
                    row(step, number: offset + 1)
                }
            }
            if context == .overview {
                Text("这一栏在必需项全部完成后会从概览页消失；侧栏的「开始使用」一直在，随时能回来。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
                if let handout = step.handout {
                    self.handout(handout)
                }
            }
            Spacer(minLength: 12)
            actions(step)
        }
        .padding(.vertical, 9)
    }

    /// 这一步要用户拿走的那串文本：命令或地址。
    ///
    /// 复制按钮就贴着文本本身，不进右侧的操作区——右侧那些是「让 RouteBar 去做某件事」，
    /// 而这一颗是「把眼前这行拿走」，混在一起时用户认不出哪个按钮对应哪串东西。
    /// 订阅地址那一步做完之后右侧本来空着（`actions` 对已完成步骤不出按钮），
    /// 恰恰是它最需要给出东西的时候。
    private func handout(_ text: String) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            Button("复制") { model.copyText(text) }
                .controlSize(.small)
        }
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
