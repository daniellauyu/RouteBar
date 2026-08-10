import Foundation

/// 一键流程里单个步骤的结果。
///
/// 「跳过」和「失败」必须分开：跳过是 RouteBar 本来就做不了（订阅地址、Surge 配置），
/// 失败是它试了但没成。合成一种之后，用户看到一片橙色，分不出哪些是自己该动手的、
/// 哪些是真的出问题了。
enum SetupStepOutcome: Sendable, Equatable {
    case running
    case done(String)
    case skipped(String)
    case failed(String)

    var detail: String {
        switch self {
        case .running: "正在处理…"
        case .done(let text), .skipped(let text), .failed(let text): text
        }
    }
}

/// 一次「一键完成」的运行状态。
///
/// 存在 AppModel 里而不是视图的 `@State`：概览页的引导卡片和「开始使用」页是同一份
/// 视图的两个实例，跑到一半切页面时，状态放在视图里会连同进度一起丢掉。
struct SetupAutomationRun: Sendable, Equatable {
    var isRunning = false
    var outcomes: [SetupStep.Kind: SetupStepOutcome] = [:]
    /// 跑完之后的结论。跑之前和跑的过程中都是 nil。
    var report: Report?

    // MARK: - 进度
    //
    // 「看着在动」不是装饰。这条流水线里最慢的一步（brew 装 sing-box）可以跑好几分钟，
    // 期间如果只有一个转圈的菊花，用户没有任何办法区分「在下载」和「已经挂死」——
    // 唯一能做的就是干等，等到自己先放弃。所以三样东西缺一不可：整体走到第几步、
    // 当前这步在干什么、已经等了多久。

    /// 正在处理的步骤。跑完或没在跑时为 nil。
    var currentKind: SetupStep.Kind?
    /// 当前步骤的开始时刻，用来显示已用时。
    var currentStartedAt: Date?
    /// 当前步骤的实时状态行：brew 的输出、下载的字节数……
    var statusText: String?
    /// 当前步骤的确定进度（0…1）。只有下载这类知道总量的阶段给得出来。
    var fraction: Double?
    /// 已经处理完的步骤数，与 `totalSteps` 一起构成整体进度。
    var completedSteps = 0
    var totalSteps = 0

    /// 整体完成比例。用于那根确定进度条——步骤总数是已知的，所以这一根永远给得出来，
    /// 哪怕当前步骤自己报不出百分比。
    var overallFraction: Double {
        guard totalSteps > 0 else { return 0 }
        return Double(completedSteps) / Double(totalSteps)
    }

    /// 「第 3/7 步」里的那个 3。正在跑的这一步算当前步，所以要 +1。
    var currentStepNumber: Int { min(completedSteps + 1, max(totalSteps, 1)) }

    /// 收尾时给出的一句话结论 + 还剩什么。
    struct Report: Sendable, Equatable {
        enum Verdict: Sendable, Equatable {
            /// 必需项全绿，可以直接用了。
            case ready
            /// RouteBar 那部分做完了，剩下的只能用户自己做。
            case needsYou
            /// 有步骤真的失败了。
            case failed
        }

        let verdict: Verdict
        let headline: String
        /// 逐条列出还差什么。空数组表示没剩下的了。
        let remaining: [String]
    }

    var hasStarted: Bool { isRunning || report != nil }

    func outcome(for kind: SetupStep.Kind) -> SetupStepOutcome? { outcomes[kind] }
}
