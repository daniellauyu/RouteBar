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
            // 跑的时候是进度条，跑完换成结论——同一个位置，一件事的两个阶段。
            //
            // 都摆在步骤上方而不是页尾：正在跑时用户盯的是「到哪儿了」，跑完之后要的是
            // 「所以能用了吗」，两种情况下这都是他第一眼该看到的东西。
            if model.setupRun.isRunning {
                SetupRunProgressBanner(run: model.setupRun, title: runningTitle)
            } else if let report = model.setupRun.report {
                SetupRunReportBanner(report: report) { model.runSetupAutomation() }
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

    /// 正在跑的那一步叫什么。进度条要显示它，而标题只有清单知道。
    private var runningTitle: String {
        guard let kind = model.setupRun.currentKind else { return "正在配置" }
        return model.setupChecklist.steps.first { $0.kind == kind }?.title ?? "正在配置"
    }

    private func header(_ checklist: SetupChecklist) -> some View {
        HStack(spacing: 10) {
            Text("开始使用").font(.headline)
            Spacer()
            Text(checklist.remainingRequiredCount == 0
                 ? "必需项已完成"
                 : "还有 \(checklist.remainingRequiredCount) 步")
                .font(.caption)
                .foregroundStyle(checklist.remainingRequiredCount == 0 ? .green : .orange)
            SetupAutomationButton()
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
                if let outcome = model.setupRun.outcome(for: step.kind), !isStale(outcome, step) {
                    runOutcome(outcome)
                }
                if let handout = step.handout {
                    self.handout(handout)
                }
            }
            Spacer(minLength: 12)
            actions(step)
        }
        .padding(.vertical, 9)
    }

    /// 一键跑完之后，用户自己把这一步做掉了（典型情况：回去粘了订阅地址）。
    ///
    /// 那句「轮到你了」这时已经过期，还挂着的话，一行绿勾下面配一句橙色的「需要你来做」，
    /// 看着像是没做成。成功与失败的记录不算过期——它们说的是「刚才发生了什么」，仍然成立。
    private func isStale(_ outcome: SetupStepOutcome, _ step: SetupStep) -> Bool {
        if case .skipped = outcome { return step.isDone }
        return false
    }

    private func hasFailed(_ step: SetupStep) -> Bool {
        if case .failed = model.setupRun.outcome(for: step.kind) { return true }
        return false
    }

    /// 一键流程给这一步留下的话。
    ///
    /// 单独一行、带颜色，不并进上面那段说明：说明讲的是「这一步是什么」，
    /// 这里讲的是「刚才那次跑到这儿发生了什么」，混成一段之后失败原因会被淹掉。
    private func runOutcome(_ outcome: SetupStepOutcome) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: outcome.symbol).font(.caption2)
            Text(outcome.detail)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .foregroundStyle(outcome.tint)
        .padding(.top, 2)
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
            // 已完成永远优先显示绿勾：这一步的事实是「它成了」，
            // 而不是「刚才那次运行对它做了什么」。
            if step.isDone {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if case .running = model.setupRun.outcome(for: step.kind) {
                ProgressView().controlSize(.small)
            } else if let outcome = model.setupRun.outcome(for: step.kind) {
                Image(systemName: outcome.symbol)
                    .foregroundStyle(outcome.tint)
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
        // 跑的过程中把逐步按钮收起来：这时点「创建目录」会和流水线同时动同一批文件，
        // 而且用户本来就是为了不用逐个点才按的一键。
        if step.isDone || model.setupRun.isRunning {
            EmptyView()
        } else if hasFailed(step), step.automation == .automatic {
            // 这一步刚失败过，而且本来就是 RouteBar 能自己做的：只给「重试」。
            //
            // 不和下面那些按钮并排摆——对自动步骤来说「创建目录」「启动服务」本来就
            // 等于重试一次，两颗按钮做同一件事只会让人猜哪颗才对。重试单独一步而不是
            // 重跑整条流水线：失败常常是一次性的（网络抖了、brew 的锁没释放），
            // 为此把已经成功的六步重做一遍毫无道理。
            Button("重试") { model.retrySetupStep(step.kind) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        } else {
            HStack(spacing: 6) {
                switch step.kind {
                case .singBox:
                    // 「重新检测」留着：自己刚在终端里装完的人只需要 RouteBar 再看一眼，
                    // 不该被逼着走一次自动安装。
                    Button("重新检测") { model.redetectSingBox() }
                    Button("立即安装") { model.installSingBoxOnly() }
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
                case .output:
                    if model.settings.outputMode.servesSubscription {
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

/// 「一键完成」按钮。
///
/// 概览页卡片的标题行和「开始使用」页的顶栏共用这一个：两处各画一个的话，
/// 「什么时候该禁用」这条规则迟早会在一边被改漏。
struct SetupAutomationButton: View {
    @EnvironmentObject private var model: AppModel

    var controlSize: ControlSize = .small

    var body: some View {
        Button {
            model.runSetupAutomation()
        } label: {
            if model.setupRun.isRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在配置…")
                }
            } else {
                Label("一键完成", systemImage: "wand.and.stars")
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(controlSize)
        .disabled(model.setupRun.isRunning || !model.setupChecklist.canAutomate)
        .help("按顺序做掉 RouteBar 能代劳的步骤：安装 sing-box、创建目录、安装 LaunchAgent、"
            + "启动服务、开机自启。订阅地址和 Surge 配置只能你自己来。")
    }
}

/// 正在跑时的进度条。
///
/// 三样信息缺一不可，因为它们回答的是三个不同的问题：整体走到第几步（还要等多久）、
/// 这一步在干什么（它还活着吗）、已经等了多久（该不该开始怀疑）。
/// 少了任何一样，用户面对一个转了五分钟的菊花，除了干等就只剩放弃。
struct SetupRunProgressBanner: View {
    let run: SetupAutomationRun
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("第 \(run.currentStepNumber)/\(run.totalSteps) 步 · \(title)")
                    .font(.callout.weight(.medium))
                Spacer(minLength: 12)
                elapsed
            }
            // 整体那根永远是确定的——步骤总数是已知的。当前步骤自己报得出百分比时
            // （下载），再多给一根细的，这样「整体没动但这一步在动」看得出来。
            ProgressView(value: run.overallFraction)
                .progressViewStyle(.linear)
            if let fraction = run.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(.secondary)
                    .scaleEffect(x: 1, y: 0.6, anchor: .center)
            }
            if let status = run.statusText {
                Text(status)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    /// 已用时。
    ///
    /// 用 `TimelineView` 每秒自己重画：进度靠推送更新的话，brew 沉默的那几分钟里
    /// 界面会一动不动——而那恰恰是最需要证明「它还在跑」的时候。这个数字保证在走。
    private var elapsed: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.format(run.currentStartedAt.map { context.date.timeIntervalSince($0) } ?? 0))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private static func format(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "已用时 %d:%02d", seconds / 60, seconds % 60)
    }
}

/// 一键跑完之后的结论条。
///
/// 三种结论对应三种完全不同的下一步动作：能用了、该你动手了、出错了要去查日志。
/// 合成一句「还有 N 步未完成」的话，这三种情况在界面上长得一模一样。
struct SetupRunReportBanner: View {
    let report: SetupAutomationRun.Report
    /// 重跑整条流水线。只在有步骤真的失败时才给——已经做完的步骤会被自动跳过。
    var retry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label(report.headline, systemImage: symbol)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(tint)
                    .fixedSize(horizontal: false, vertical: true)
                if report.verdict == .failed, let retry {
                    Spacer(minLength: 0)
                    Button("重试未完成的") { retry() }
                        .controlSize(.small)
                }
            }
            ForEach(report.remaining, id: \.self) { line in
                Text("· \(line)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }

    private var symbol: String {
        switch report.verdict {
        case .ready: "checkmark.seal.fill"
        case .needsYou: "hand.raised.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch report.verdict {
        case .ready: .green
        case .needsYou: .orange
        case .failed: .red
        }
    }
}
