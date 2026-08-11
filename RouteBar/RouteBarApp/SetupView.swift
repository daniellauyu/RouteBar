import AppKit
import SwiftUI

/// 「开始」页：常驻的分步引导。
///
/// 引导原来只在概览页顶部出现，必需项一做完就永久消失，有两个后果：跟着它点「去添加」
/// 跳到订阅页之后，指引就不在视野里了；而路径失效导致步骤重新变红时，用户正处在
/// 「出问题了」的心态，不会想到回概览页找它。给它一个固定入口，这两种情况都有地方可去。
///
/// 步骤列表本身仍是 `SetupChecklistCard`，与概览页共用一份。
struct SetupView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            PageBar(subtitle) {
                Button("重新检测", systemImage: "arrow.clockwise") {
                    model.redetectSingBox()
                    model.refreshLaunchAtLogin()
                }
                .disabled(model.setupRun.isRunning)
                SetupAutomationButton(controlSize: .regular)
            }
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SetupChecklistCard(context: .page)
                    if model.setupChecklist.isComplete {
                        finishedSection
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // 用户可能刚在系统设置里改了登录项，或在别处装好了 sing-box，回到窗口时重新读一次。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshLaunchAtLogin()
        }
    }

    private var subtitle: String {
        let checklist = model.setupChecklist
        if model.setupRun.isRunning {
            return "正在按顺序处理，可以在「日志」页里看实时输出。"
        }
        if !checklist.isComplete {
            let next = checklist.nextStep.map { "下一步是「\($0.title)」。" } ?? ""
            let hint = checklist.canAutomate
                ? "其中 \(checklist.automatableSteps.count) 步可以交给「一键完成」。"
                : ""
            return "还有 \(checklist.remainingRequiredCount) 步。\(next)\(hint)"
        }
        return checklist.steps.allSatisfy(\.isDone)
            ? "全部步骤都已完成。路径失效时（Homebrew 升级、Surge 换配置名）这里会重新亮起来。"
            : "必需项都已完成，剩下的是建议项。"
    }

    /// 全绿之后这一页只剩七行勾，空得像坏了；而这时用户真正需要的是「下一步去哪」。
    private var finishedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("配好之后").font(.headline)
            InfoCard {
                destination(
                    "路径变了 / 想看完整体检",
                    "「环境」页列出每一条路径的检测结果，也能直接改。",
                    label: "去环境") { model.selectedSection = .environment }
                Divider()
                destination(
                    "代理连不上",
                    "先看 sing-box 自己的输出：「服务」页有错误日志，「日志」页是 RouteBar 这一侧的记录。",
                    label: "看日志") { model.selectedSection = .logs }
                Divider()
                documentation
            }
        }
    }

    private func destination(_ title: String, _ detail: String, label: String,
                             action: @escaping () -> Void) -> some View {
        row(title, detail) {
            Button(label, action: action)
        }
    }

    /// 使用文档只在仓库里，没有随 app 打包，所以指向线上那一份。
    private var documentation: some View {
        row("日常使用与排查", "文件都写在哪、怎么彻底卸掉、按症状排查的完整清单。") {
            Link("打开文档", destination: Self.usageDocumentation)
        }
    }

    private static let usageDocumentation = URL(
        string: "https://github.com/daniellauyu/RouteBar/blob/main/docs/routebar-usage.md")!

    private func row<Action: View>(_ title: String, _ detail: String,
                                   @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            action()
                .controlSize(.small)
        }
        .padding(.vertical, 9)
    }
}
