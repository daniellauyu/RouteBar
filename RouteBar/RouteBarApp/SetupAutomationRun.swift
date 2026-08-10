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
